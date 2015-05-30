
{
    my ($sock, $interest) = @_;

    if (defined $interest and $interest != $state{$sock}{iam_interested})
    {
	debug $state{$sock}{who}, INFO, "setting interested=%d on %s",
		$interest, $sock;
	sock_write($sock, pack("NC", 1, $interest ? INTERESTED : NOT_INTERESTED));
	$state{$sock}{iam_interested} = $interest;
    }

    return $state{$sock}{iam_interested};
}

# returns an array of lengths
#
sub slices_in_block
{
    my ($id, $index, $probe) = @_;

    if ($info{$id}{piece_length})
    {
	my $len = piece_length($id, $index);
	my @ret = map $limit{request_length}, 1..ceil($len / $limit{request_length});
	$ret[$#ret] = $limit{request_length} - ($len % $limit{request_length});
	return @ret;
    }
    else
    {
	return @probe_lengths[ 0..scalar(@{ $info{$id}{working_data}||[] }) ];
    }
}

sub missing_pieces
{
    my ($id, $peer) = @_;

    confess "i was called without a high_index\n"
	unless $info{$id} and defined $info{$id}{high_index};

    unless ($info{$id} and $info{$id}{bitfield})
    {
	my @ret;

	for (my $i = 0; $i < $info{$id}{high_index}; $i++)
	{
	    push @ret, $i if $peer->[$i];
	}
	
	return @ret;
    }

    my $have = $info{$id}{bitfield};

    return unless $peer and ref $peer eq "ARRAY";

    if ($info{$id}{authoritative} and @$peer != @$have)
    {
	debug "", INFO, "peer=%d, have=%d", scalar @$peer, scalar @$have;

	if (sum(splice @$peer, scalar @$have))
	{
	    debug "", INFO, "%s has parts excess bit in it's bitfield!", $id
	}
	else
	{
	    debug "", INFO, "%s stripped harmless excess bits", $id;
	}
    }

    my @missing;

    for (my $i = 0; $i < $info{$id}{high_index}; $i++)
    {
	push @missing, $i if $peer->[$i] and not $have->[$i];
    }

    return @missing;
}

sub unpack_bitfield
{
    return [ map @{ $bit_table[ord($_)] }, split //, $_[0] ];
}

sub packed_bitfield
{
    my ($have, $expected) = @_;

    return unless $have and ref $have eq "ARRAY";

    my $ret = '';
    my @arr = @$have;
    
    while (@arr > 0)
    {
	$#arr = 7 if $#arr < 7;
	my $a = join("", map $_||0, splice @arr, 0, 8);
	$ret .= $bit_table_reverse{$a};
    }

    $ret .= "\x00"x($expected - length($ret));

    return $ret;
}

sub piece_length
{
    my ($id, $index) = @_;

    confess "i stuffed up, piece_length called for unknown piece\n"
	unless $info{$id}{piece_length};

    if ($info{$id}{total_length} and ($index + 1) * $info{$id}{piece_length} > $info{$id}{total_length})
    {
	return $info{$id}{total_length} % $info{$id}{piece_length}
    }

    return $info{$id}{piece_length};
}

sub rarest_piece
{
    my ($id, $pieces, $prefer) = @_;

    confess "i stuffed up, rarest_piece called without pieces\n"
	unless $pieces and @$pieces;

    return $prefer if defined $prefer and grep $_ == $prefer, @$pieces;

    my @peers = grep $state{$_}{id} eq $id, keys %state
	or die;

    my @lowest_idx = 0;
    my $lowest_sum;

    for (my $i = 0; $i < @$pieces; $i++)
    {
	my $sum = sum(map $state{$_}{have}[ $pieces->[$i] ], @peers)
	    or next;
	
	if (not $lowest_sum or $sum < $lowest_sum)
	{
	    @lowest_idx = ($i);
	    $lowest_sum = $sum;
	}
	elsif ($lowest_sum == $sum)
	{
	    push @lowest_idx, $i;
	}
    }

    return $pieces->[$lowest_idx[int rand(scalar @lowest_idx)]];
}

sub random_piece
{
    my ($id, $pieces, $prefer) = @_;

    confess "i stuffed up, random_piece called without pieces\n"
	unless $pieces and @$pieces;

    return $prefer if defined $prefer and grep $_ == $prefer, @$pieces;
    return $pieces->[int rand(scalar @$pieces)];
}

sub guess_agent
{
    die unless keys %agent;
    die unless $agent{"AZ"} eq "Azureus";

    for ($_[0])
    {
	return "BitTorrent $1.$2.$3" if /^M(\d)-(\d)-(\d)--/;
	return "BitComet $1" if /^exbc\x00(\d)/;
	return sprintf("%s %s", $agent{uc $1}||"Unknown: $1(".length($1).")", $2) if /^-([a-z][a-z])(\d\d\d\d)-/i;
	return sprintf("%s %s", $agent{uc $1}||"Unknown: $1(".length($1).")", $2) if /^([a-z])(\d\d\d)----/i;
	return sprintf("Unknown%s", $1 ? ": $1" : "") if /^([\w-]+)/ || 1;
    }
}

sub save_state
{
    my ($id) = @_;

    my $file = sprintf("%s/%s.meta", $path, $id);

    unless (sysopen OUT, "$file.$$", O_RDWR|O_CREAT|O_EXCL, 0644)
    {
	debug "", ERROR, "Couldn't open file to save state: $!";
	return;
    }

    syswrite OUT, freeze($info{$id});

    unless (close OUT)
    {
	unlink "$file.$$";
	debug "", ERROR, "Couldn't close $file: $!";
	return;
    }

    rename "$file.$$", $file;
}

sub restore_state
{
    my ($id) = @_;

    my $file = sprintf("%s/%s.meta", $path, $id);

    local $/ = undef;

    open IN, $file or return;
    my $buf = <IN>;
    close IN;

    $info{$id} = thaw($buf);
}

sub store
{
    my $id = shift;
    my $offset = shift;
    my $buf = shift;

    my $file = sprintf("%s/%s", $path, $id);

    debug "", INFO, "STORING: %s, offset=%s, length=%d", $file, $offset, length($buf);

    unless (sysopen OUT, $file, O_RDWR|O_CREAT, 0644)
    {
	debug "", ERROR, "Couldn't open file to save block: $!";
	return;
    }
    
    unless (sysseek(OUT, $offset, 0)
	    and syswrite(OUT, $buf)
	    and close(OUT))
    {
	debug "", ERROR, "Couldn't write file: $!";
	return;
    }

    return 1;
}

sub debug
{
    my ($who, $lvl, $fmt, @args) = @_;

    if ($who =~ /^([\d\.]+)/ and -e "/tmp/debug.$1")
    {
	$fh{$1} ||= new IO::File "/tmp/debug.$1", O_WRONLY|O_APPEND;

	printf { $fh{$1} } "%21s: $fmt\n", $who, @args;
    }

    printf STDERR "%21s: $fmt\n", $who, @args
	if $DEBUG >= $lvl;

    exit(1) if $lvl == FATAL;
}

sub min { return (sort { $a <=> $b } @_)[0]; }
sub max { return (sort { $a <=> $b } @_)[-1]; }

sub sum
{
    my $ret = 0;
    $ret += $_ foreach @_;
    return $ret;
}

sub dump_hex
{
    my @c = split //, $_[0];

    while (@c)
    {
	my @r = splice(@c, 0, 20);
	
	debug "", DATA, "[%02d] ".("%02x "x@r).("   "x(20-@r))." %-20s", scalar(@r), map(ord($_), @r), join("", map /^\w$/ ? $_ : ".", @r);
    }
}

sub hex_str
{
    return sprintf("%02x"x(length($_[0])), map ord($_), split //, $_[0]);
}

# vi: nowrap cin ts=8 sw=4
