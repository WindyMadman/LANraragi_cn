package LANraragi::Model::Search;

use strict;
use warnings;

use utf8;
use List::Util qw(min);
use Redis;
use Storable qw/ nfreeze thaw /;
use Sort::Naturally;

use LANraragi::Utils::Generic qw(split_workload_by_cpu remove_spaces);
use LANraragi::Utils::Database qw(redis_decode redis_encode);
use LANraragi::Utils::Logging qw(get_logger);

use LANraragi::Model::Archive;
use LANraragi::Model::Category;

# do_search (filter, category_id, page, key, order, newonly, untaggedonly)
# Performs a search on the database.
sub do_search {
    
    my ( $filter, $category_id, $start, $sortkey, $sortorder, $newonly, $untaggedonly ) = @_;

    my $redis = LANraragi::Model::Config->get_redis_search;
    my $logger = get_logger( "Search Engine", "lanraragi" );

    unless ( $redis->exists("LAST_JOB_TIME") ) {
        $logger->error("搜索引擎尚未初始化。 请稍等几秒钟。");
        return ( -1, -1, () );
    }

    # Search filter results
    my $total = $redis->zcard("LRR_TITLES") + 0;    # Total number of archives (as int)

    # Look in searchcache first
    my $sortorder_inv = $sortorder ? 0 : 1;
    my $cachekey      = redis_encode("$category_id-$filter-$sortkey-$sortorder-$newonly-$untaggedonly");
    #print $cachekey . "\n";
    my $cachekey_inv  = redis_encode("$category_id-$filter-$sortkey-$sortorder_inv-$newonly-$untaggedonly");
    my ( $cachehit, @filtered ) = check_cache( $cachekey, $cachekey_inv );

    unless ($cachehit) {
        $logger->debug("没有可用的缓存，进行完整的DB解析。");
        @filtered = search_uncached( $category_id, $filter, $sortkey, $sortorder, $newonly, $untaggedonly );

        # Cache this query in the search database
        eval { $redis->hset( "LRR_SEARCHCACHE", $cachekey, nfreeze \@filtered ); };
    }
    $redis->quit();

    # If start is negative, return all possible data.
    if ( $start == -1 ) {
        return ( $total, $#filtered + 1, @filtered );
    }

    # Only get the first X keys
    my $keysperpage = LANraragi::Model::Config->get_pagesize;

    # Return total keys and the filtered ones
    my $end = min( $start + $keysperpage - 1, $#filtered );
    return ( $total, $#filtered + 1, @filtered[ $start .. $end ] );
}

sub check_cache {

    my ( $cachekey, $cachekey_inv ) = @_;
    my $redis = LANraragi::Model::Config->get_redis_search;
    my $logger = get_logger( "Search Cache", "lanraragi" );

    my @filtered = ();
    my $cachehit = 0;
    $logger->debug("搜索请求： $cachekey");

    if ( $redis->exists("LRR_SEARCHCACHE") && $redis->hexists( "LRR_SEARCHCACHE", $cachekey ) ) {
        $logger->debug("将缓存用于此查询。");
        $cachehit = 1;

        # Thaw cache and use that as the filtered list
        my $frozendata = $redis->hget( "LRR_SEARCHCACHE", $cachekey );
        @filtered = @{ thaw $frozendata };

    } elsif ( $redis->exists("LRR_SEARCHCACHE") && $redis->hexists( "LRR_SEARCHCACHE", $cachekey_inv ) ) {
        $logger->debug("与对面的排序订单存在缓存密钥.");
        $cachehit = 1;

        # Thaw cache, invert the list to match the sortorder and use that as the filtered list
        my $frozendata = $redis->hget( "LRR_SEARCHCACHE", $cachekey_inv );
        @filtered = reverse @{ thaw $frozendata };
    }

    $redis->quit();
    return ( $cachehit, @filtered );
}

# Grab all our IDs, then filter them down according to the following filters and tokens' ID groups.
sub search_uncached {

    my ( $category_id, $filter, $sortkey, $sortorder, $newonly, $untaggedonly ) = @_;
    my $redis    = LANraragi::Model::Config->get_redis_search;
    my $redis_db = LANraragi::Model::Config->get_redis;
    my $logger   = get_logger( "Search Core", "lanraragi" );

    # Compute search filters
    my @tokens = compute_search_filter($filter);

    # Prepare array: For each token, we'll have a list of matching archive IDs.
    # We intersect those lists as we proceed to get the final result.
    # Start with all our IDs.
    my @filtered = $redis_db->keys('????????????????????????????????????????');

    # If we're using a category, we'll need to get its source data first.
    my %category = LANraragi::Model::Category::get_category($category_id);

    if (%category) {

        # We're using a category! Update its lastused value.
        $redis->hset( $category_id, "last_used", time() );

        # If the category is dynamic, get its search predicate and add it to the tokens.
        # If it's static however, we can use its ID list as the base for our result array.
        if ( $category{search} ne "" ) {
            my @cat_tokens = compute_search_filter( $category{search} );
            push @tokens, @cat_tokens;
        } else {
            @filtered = intersect_arrays( $category{archives}, \@filtered, 0 );
        }
    }

    # If the untagged filter is enabled, call the untagged files API
    if ($untaggedonly) {
        my @untagged = $redis->smembers("LRR_UNTAGGED");
        @filtered = intersect_arrays( \@untagged, \@filtered, 0 );
    }

    # Check new filter
    if ($newonly) {
        my @new = $redis->smembers("LRR_NEW");
        @filtered = intersect_arrays( \@new, \@filtered, 0 );
    }

    # Iterate through each token and intersect the results with the previous ones.
    unless ( scalar @tokens == 0 || scalar @filtered == 0 ) {
        foreach my $token (@tokens) {

            my $tag     = $token->{tag};
            my $isneg   = $token->{isneg};
            my $isexact = $token->{isexact};

            $logger->debug("正在搜索 $tag, isneg=$isneg, isexact=$isexact");

            # Encode tag as we'll use it in redis operations
            $tag = redis_encode($tag);

            my @ids = ();

           # Specific case for pagecount searches
           # You can search for galleries with a specific number of pages with pages:20, or with a page range: pages:>20 pages:<=30.
            if ( $tag =~ /^pages:(>|<|>=|<=)?(\d+)$/ ) {
                my $operator  = $1;
                my $pagecount = $2;

                $logger->debug("搜索具有页面的ID $operator $pagecount");

                # If no operator is specified, we assume it's an exact match
                $operator = "=" if !$operator;

                # Go through all IDs in @filtered and check if they have the right pagecount
                # This could be sped up with an index, but it's probably not worth it.
                foreach my $id (@filtered) {
                    my $count = $redis_db->hget( $id, "pagecount" );
                    if (   ( $operator eq "=" && $count == $pagecount )
                        || ( $operator eq ">"  && $count > $pagecount )
                        || ( $operator eq ">=" && $count >= $pagecount )
                        || ( $operator eq "<"  && $count < $pagecount )
                        || ( $operator eq "<=" && $count <= $pagecount ) ) {
                        push @ids, $id;
                    }
                }
            }

            # For exact tag searches, just check if an index for it exists
            if ( $isexact && $redis->exists("INDEX_$tag") ) {

                # Get the list of IDs for this tag
                @ids = $redis->smembers("INDEX_$tag");
                $logger->debug( "找到了 $tag 的索引，包含 " . scalar @ids . "个 ID" );
            } else {

                # Get index keys that match this tag.
                # If the tag has a namespace, We don't add a wildcard at the start of the tag to keep it intact.
                # Otherwise, we add a wildcard at the start to match all namespaces.
                my $indexkey = $tag =~ /:/ ? "INDEX_$tag*" : "INDEX_*$tag*";
                my @keys = $redis->keys($indexkey);

                # Get the list of IDs for each key
                foreach my $key (@keys) {
                    my @keyids = $redis->smembers($key);
                    $logger->trace( "找到了 $tag 的索引 $key，包含了 " . scalar @ids . " 个 ID" );
                    push @ids, @keyids;
                }
            }

            # Append fuzzy title search
            my $namesearch = $isexact ? "$tag\x00*" : "*$tag*";
            my $scan = -1;
            while ( $scan != 0 ) {

                # First iteration
                if ( $scan == -1 ) { $scan = 0; }
                $logger->trace("正在扫描 $namesearch, cursor=$scan");

                my @result = $redis->zscan( "LRR_TITLES", $scan, "MATCH", $namesearch, "COUNT", 100 );
                $scan = $result[0];

                foreach my $title ( @{ $result[1] } ) {

                    if ( $title eq "0" ) { next; }    # Skip scores
                    $logger->trace("找到标题匹配项: $title");

                    # Strip everything before \x00 to get the ID out of the key
                    my $id = substr( $title, index( $title, "\x00" ) + 1 );
                    push @ids, $id;
                }
            }

            if ( scalar @ids == 0 && !$isneg ) {

                # 没有更多的结果，我们可以在这里结束搜索
                $logger->trace("该标记没有结果，正在停止搜索。");
                @filtered = ();
                last;
            } else {
                $logger->trace( "找到此标记的 " . scalar @ids . " 个结果." );

                # 将新列表与以前的列表相交
                @filtered = intersect_arrays( \@ids, \@filtered, $isneg );
            }
        }
    }

    if ( $#filtered > 0 ) {
        $logger->debug( "筛选后找到了 " . $#filtered . " 个结果" );

        if ( !$sortkey ) {
            $sortkey = "title";
        }

        if ( $sortkey eq "title" ) {
            my @ordered = ();

            # For title sorting, we can just use the LRR_TITLES set, which is sorted lexicographically (but not naturally).
            @ordered = nsort( $redis->zrangebylex( "LRR_TITLES", "-", "+" ) );
            if ($sortorder) {
                @ordered = reverse(@ordered);
            }

            # Remove the titles from the keys, which are stored as "title\x00id"
            @ordered = map { substr( $_, index( $_, "\x00" ) + 1 ) } @ordered;

            $logger->trace( "有序列表中的示例元素: " . $ordered[0] );

            # Just intersect the ordered list with the filtered one to get the final result
            @filtered = intersect_arrays( \@filtered, \@ordered, 0 );
        } else {

            # For other sorting, we need to get the metadata for each archive and sort it manually.
            # Just use the old sort algorithm at this point.
            @filtered = sort_results( $sortkey, $sortorder, @filtered );

            # We could theoretically use the tag indexes for this by scanning them all
            # to find the filtered IDs and then ordering on those namespace/ID pairs, but that's a lot of work for little gain.
        }
    }

    $redis->quit();
    $redis_db->quit();
    return @filtered;
}

# intersect_arrays(@array1, @array2, $isneg)
# Intersect two arrays and return the result. If $isneg is true, return the difference instead.
sub intersect_arrays {

    my ( $array1, $array2, $isneg ) = @_;

    # If array1 is empty, just return an empty array or the second array if $isneg is true
    if ( scalar @$array1 == 0 ) {
        return $isneg ? @$array2 : ();
    }

    # If array2 is empty, die since this sub shouldn't even be used in that case
    if ( scalar @$array2 == 0 ) {
        die "intersect_arrays called with an empty array2";
    }

    my %hash = map { $_ => 1 } @$array1;
    my @result;

    if ($isneg) {
        @result = grep { !exists $hash{$_} } @$array2;
    } else {
        @result = grep { exists $hash{$_} } @$array2;
    }

    return @result;
}

# compute_search_filter($filter)
# Transform the search engine syntax into a list of tokens.
# A token object contains the tag, whether it must be an exact match, and whether it must be absent.
sub compute_search_filter {

    my $filter = shift;
    my $logger = get_logger( "Search Core", "lanraragi" );
    my @tokens = ();
    if ( !$filter ) { $filter = ""; }

    # Special characters:
    # "" for exact search (or $, but is that one really useful now?)
    # ?/_ for any character
    # * % for multiple characters
    # - to exclude the next tag

    $b = reverse($filter);
    while ( $b ne "" ) {

        my $char  = chop $b;
        my $isneg = 0;

        # Skip spaces
        while ( $char eq " " && $b ne "" ) {
            $char = chop $b;
        }

        if ( $char eq "-" ) {
            $isneg = 1;
            $char  = chop $b;
        }

        # Get characters until the next comma, or the next " if the following char is "
        my $delimiter = ',';
        if ( $char eq '"' ) {
            $delimiter = '"';
            $char      = chop $b;
        }

        my $tag     = "";
        my $isexact = 0;
      TAGBUILD: while (1) {
            if ( $char eq $delimiter || $char eq "" ) { last TAGBUILD; }
            $tag  = $tag . $char;    # Add characters in reverse order since we used reverse earlier on
            $char = chop $b;
        }

        #If last char is $ or delimiter was ", enable isexact
        if ( $delimiter eq '"' ) {
            $isexact = 1;

            # Quotes then $ is an accepted syntax, even though it does nothing
            $char = chop $b;
            unless ( $char eq "\$" ) {
                $b = $b . $char;
            }
        } else {
            $char = chop $tag;
            if ( $char eq "\$" ) {
                $isexact = 1;
            } else {
                $tag = $tag . $char;
            }
        }

        # Escape already present regex characters
        $logger->debug("预转义标签: $tag");

        remove_spaces($tag);

        # Escape characters according to redis zscan rules
        $tag =~ s/([\[\]\^\\])/\\$1/g;

        # Replace placeholders with glob-style patterns,
        # ? or _ => ?
        $tag =~ s/\_/\?/g;

        # * or % => *
        $tag =~ s/\%/\*/g;

        push @tokens,
          { tag     => lc($tag),
            isneg   => $isneg,
            isexact => $isexact
          };
    }
    return @tokens;
}

sub sort_results {

    my ( $sortkey, $sortorder, @filtered ) = @_;
    my $redis = LANraragi::Model::Config->get_redis;

    my $re = qr/$sortkey/;

   # Map our archives to a hash, where the key is the ID and the value is the first tag we found that matches the sortkey/namespace.
   # (If no tag, defaults to "zzzz")
    my %tmpfilter = map { $_ => ( $redis->hget( $_, "tags" ) =~ m/.*${re}:(.*)(\,.*|$)/ ) ? $1 : "zzzz" } @filtered;

    my @sorted = map { $_->[0] }    # Map back to only having the ID
      sort { ncmp( $a->[1], $b->[1] ) }    # Sort by the tag
      map { [ $_, lc( $tmpfilter{$_} ) ] } # Map to an array containing the ID and the lowercased tag
      keys %tmpfilter;                     # List of IDs

    if ($sortorder) {
        @sorted = reverse @sorted;
    }

    return @sorted;
}

1;
