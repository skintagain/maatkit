# This program is copyright (c) 2007 Baron Schwartz.
# Feedback and improvements are welcome.
#
# THIS PROGRAM IS PROVIDED "AS IS" AND WITHOUT ANY EXPRESS OR IMPLIED
# WARRANTIES, INCLUDING, WITHOUT LIMITATION, THE IMPLIED WARRANTIES OF
# MERCHANTIBILITY AND FITNESS FOR A PARTICULAR PURPOSE.
#
# This program is free software; you can redistribute it and/or modify it under
# the terms of the GNU General Public License as published by the Free Software
# Foundation, version 2; OR the Perl Artistic License.  On UNIX and similar
# systems, you can issue `man perlgpl' or `man perlartistic' to read these
# licenses.
#
# You should have received a copy of the GNU General Public License along with
# this program; if not, write to the Free Software Foundation, Inc., 59 Temple
# Place, Suite 330, Boston, MA  02111-1307  USA.
# ###########################################################################
# TableChecksum package $Revision$
# ###########################################################################
use strict;
use warnings FATAL => 'all';

package TableChecksum;

use English qw(-no_match_vars);
use POSIX qw(ceil);
use List::Util qw(min max);

our %ALGOS = (
   CHECKSUM => { pref => 0, hash => 0 },
   ACCUM    => { pref => 1, hash => 1 },
   BIT_XOR  => { pref => 2, hash => 1 },
);

sub new {
   bless {}, shift;
}

# Options:
#   algorithm   Optional: one of CHECKSUM, ACCUM, BIT_XOR
#   vp          VersionParser object
#   dbh         DB handle
#   where       bool: whether user wants a WHERE clause applied
#   chunk       bool: whether user wants to checksum in chunks
#   replicate   bool: whether user wants to do via replication
#   count       bool: whether user wants a row count too
sub best_algorithm {
   my ( $self, %opts ) = @_;
   my ($alg, $vp, $dbh) = @opts{ qw(algorithm vp dbh) };
   my @choices = sort { $ALGOS{$a}->{pref} <=> $ALGOS{$b}->{pref} } keys %ALGOS;
   die "Invalid checksum algorithm $alg"
      if $alg && ! grep { $_ eq $alg } @choices;

   # CHECKSUM is eliminated by lots of things...
   if ( 
      $opts{where} || $opts{chunk}        # CHECKSUM does whole table
      || $opts{replicate}                 # CHECKSUM can't do INSERT.. SELECT
      || !$vp->version_ge($dbh, '4.1.1')) # CHECKSUM doesn't exist
   {
      @choices = grep { $_ ne 'CHECKSUM' } @choices;
   }

   # BIT_XOR isn't available till 4.1.1 either
   if ( !$vp->version_ge($dbh, '4.1.1') ) {
      @choices = grep { $_ ne 'BIT_XOR' } @choices;
   }

   # Choose the best (fastest) among the remaining choices.
   if ( $alg && grep { $_ eq $alg } @choices ) {
      # Honor explicit choices.
      return $alg;
   }

   # If the user wants a count, prefer something other than CHECKSUM, because it
   # requires an extra query for the count.
   if ( $opts{count} && grep { $_ ne 'CHECKSUM' } @choices ) {
      @choices = grep { $_ ne 'CHECKSUM' } @choices;
   }

   return $choices[0];
}

sub is_hash_algorithm {
   my ( $self, $algorithm ) = @_;
   return $ALGOS{$algorithm} && $ALGOS{$algorithm}->{hash};
}

sub choose_hash_func {
   my ( $self, %opts ) = @_;
   my @funcs = qw(SHA1 MD5);
   if ( $opts{func} && !grep { uc $opts{func} eq $_ } @funcs ) {
      unshift @funcs, $opts{func};
   }
   my ($result, $error);
   do {
      my $func;
      eval {
         $func = shift(@funcs);
         $opts{dbh}->do("SELECT $func('test-string')");
         $result = $func;
      };
      if ( $EVAL_ERROR && $EVAL_ERROR =~ m/failed: (.*?) at \S+ line/ ) {
         $error .= qq{$func cannot be used because "$1"\n};
      }
   } while ( @funcs && !$result );

   die $error unless $result;
   return $result;
}

# Figure out which slice in a sliced BIT_XOR checksum should have the actual
# concat-columns-and-checksum, and which should just get variable references.
# Returns the slice.  I'm really not sure if this code is needed.  It always
# seems the last slice is the one that works.  But I'd rather be paranoid.
sub optimize_xor {
   my ( $self, %opts ) = @_;
   my ( $dbh, $func ) = @opts{qw(dbh func)};

   my $opt_slice = 0;
   my $unsliced  = uc $dbh->selectall_arrayref("SELECT $func('a')")->[0]->[0];
   my $sliced    = '';
   my $start     = 1;
   my $crc_wid   = length($unsliced) < 16 ? 16 : length($unsliced);

   do { # Try different positions till sliced result equals non-sliced.
      $dbh->do('SET @crc := NULL, @cnt := 0');
      my $slices = $self->make_xor_slices(
         query     => "\@crc := $func('a')",
         crc_wid   => $crc_wid,
         opt_slice => $opt_slice,
      );

      my $sql = "SELECT CONCAT($slices) AS TEST FROM (SELECT NULL) AS x";
      $sliced = ($dbh->selectrow_array($sql))[0];
      if ( $sliced ne $unsliced ) {
         $start += 16;
         ++$opt_slice;
      }
   } while ( $start < $crc_wid && $sliced ne $unsliced );

   return $sliced eq $unsliced ? $opt_slice : undef;
}

# Returns an expression that will do a bitwise XOR over a very wide integer,
# such as that returned by SHA1, which is too large to just put into BIT_XOR().
# $query is an expression that returns a row's checksum, $crc_wid is the width
# of that expression in characters.  If the opt_slice argument is given, use a
# variable to avoid calling the $query expression multiple times.  The variable
# goes in slice $opt_slice.
sub make_xor_slices {
   my ( $self, %opts ) = @_;
   my ( $query, $crc_wid, $opt_slice )
      = @opts{qw(query crc_wid opt_slice)};

   # Create a series of slices with @crc as a placeholder.
   my @slices;
   for ( my $start = 1; $start <= $crc_wid; $start += 16 ) {
      my $len = $crc_wid - $start + 1;
      if ( $len > 16 ) {
         $len = 16;
      }
      push @slices,
         "LPAD(CONV(BIT_XOR("
         . "CAST(CONV(SUBSTRING(\@crc, $start, $len), 16, 10) AS UNSIGNED))"
         . ", 10, 16), $len, '0')";
   }

   # Replace the placeholder with the expression.  If specified, add a
   # user-variable optimization so the expression goes in only one of the
   # slices.
   if ( defined $opt_slice && $opt_slice < @slices ) {
      $slices[$opt_slice] =~ s/\@crc/\@crc := $query/;
   }
   else {
      map { s/\@crc/$query/ } @slices;
   }

   return join(', ', @slices);
}

# Generates a checksum query for a given table.  Arguments:
# *   table     Struct as returned by TableParser::parse()
# *   quoter    Quoter()
# *   func      SHA1, MD5, etc
# *   sep       (Optional) Separator for CONCAT_WS(); default #
# *   cols      (Optional) arrayref of columns to checksum
sub make_row_checksum {
   my ( $self, %args ) = @_;
   my ( $table, $quoter, $func )
      = @args{ qw(table quoter func) };

   my $sep = $args{sep} || '#';
   $sep =~ s/'//g;
   $sep ||= '#';

   # Generate the expression that will turn a row into a checksum.
   # Choose columns.  Normalize query results: make FLOAT and TIMESTAMP
   # stringify uniformly.
   my %cols = map { $_ => 1 } ($args{cols} ? @{$args{cols}} : @{$table->{cols}});
   my @cols =
      map {
         my $type = $table->{type_for}->{$_};
         my $result = $quoter->quote($_);
         if ( $type eq 'timestamp' ) {
            $result .= ' + 0';
         }
         elsif ( $type =~ m/float|double/ && $args{precision} ) {
            $result = "ROUND($result, $args{precision})";
         }
         $result;
      }
      grep {
         $cols{$_}
      }
      @{$table->{cols}};

   # Add a bitmap of which nullable columns are NULL.
   my @nulls = grep { $cols{$_} } @{$table->{null_cols}};
   if ( @nulls ) {
      my $bitmap = "CONCAT("
         . join(', ', map { 'ISNULL(' . $quoter->quote($_) . ')' } @nulls)
         . ")";
      push @cols, $bitmap;
   }

   my $query = @cols > 1
             ? "$func(CONCAT_WS('$sep', " . join(', ', @cols) . '))'
             : "$func($cols[0])";

   return $query;
}

1;

__DATA__

   # Make the query.
   if ( $strat eq 'BIT_XOR' ) {

      # This checksum algorithm concatenates the columns in each row and
      # checksums them, then slices this checksum up into 16-character chunks.
      # It then converts them BIGINTs with the CONV() function, and then
      # groupwise XORs them to produce an order-independent checksum of the
      # slice over all the rows.  It then converts these back to base 16 and
      # puts them back together.  The effect is the same as XORing a very wide
      # (32 characters = 128 bits for MD5, and SHA1 is even larger) unsigned
      # integer over all the rows.

      my $slices = $tc->make_slices(
         query     => $chks,
         crc_wid   => $crc_wid,
         opt_slice => $opt_slice,
      );

      if ( $opts{R} ) {
         $query = "REPLACE /*progress_comment*/ INTO $opts{R}"
            . "(db, tbl, chunk, boundaries, this_cnt, this_crc) "
            . "SELECT '$db', '$tbl', ?, ?, COUNT(*), CONCAT($slices) AS crc "
            . "FROM `$db`.`$tbl`$opts{W}";
      }
      else {
         $query = "SELECT /*progress_comment*/ COUNT(*) as cnt, CONCAT($slices) AS crc FROM `$db`.`$tbl`$opts{W}";
      }

   }
   else { # Use an accumulator variable.
      # Find whether there's a PK (for order-by).  Since the accumulator
      # variable re-checksums every row combined with the previous row's
      # checksum, row order matters.
      my $index = $opts{i}                           ? " USE INDEX(`$opts{i}`)"
                : $ddl =~ m/PRIMARY KEY\s*\((.*?)\)/ ? ' USE INDEX(PRIMARY)'
                : '';

      # Generate the query.  This query relies on @crc being NULL, and @cnt
      # being 0 when it begins.  It checksums each row, appends it to the
      # running checksum, and checksums the two together.  In this way it acts
      # as an accumulator for all the rows.  It then prepends a steadily
      # increasing number to the left, left-padded with zeroes, so each
      # checksum taken is stringwise greater than the last.  In this way the
      # MAX() function can be used to return the last checksum calculated.
      # @cnt is not used for a row count, it is only used to make MAX() work
      # correctly.
      if ( $opts{R} ) {
         $query = "REPLACE /*progress_comment*/ INTO $opts{R}"
            . "(db, tbl, chunk, boundaries, this_cnt, this_crc) "
            . "SELECT '$db', '$tbl', ?, ?, COUNT(*) AS cnt, RIGHT(MAX("
            . "\@crc := CONCAT(LPAD(\@cnt := \@cnt + 1, 16, '0'), $func(CONCAT_WS('$opts{s}', \@crc, $chks)))"
            . "), $crc_wid) AS crc FROM `$db`.`$tbl`$index$opts{W}";
      }
      else {
         $query = "SELECT /*progress_comment*/ COUNT(*) AS cnt, RIGHT(MAX("
            . "\@crc := CONCAT(LPAD(\@cnt := \@cnt + 1, 16, '0'), $func(CONCAT_WS('$opts{s}', \@crc, $chks)))"
            . "), $crc_wid) AS crc FROM `$db`.`$tbl`$index$opts{W}";
      }
   }
}

# Generates a checksum query for a given table.  Arguments:
# *   table     Struct as returned by TableParser::parse()
# *   quoter    Quoter()
# *   algorithm Any of @ALGOS
# *   func      SHA1, MD5, etc
# *   crc_wid   Width of the string returned by func
# *   opt_slice (Optional) Which slice gets opt_xor (see make_xor_slices()).
# *   cols      (Optional) arrayref of columns to checksum
# sub make_checksum_query {
 #   my ( $self, %args ) = @_;
  #  my ( $table, $quoter, $algorithm, $func, $crc_wid, $opt_slice )
   #    = @opts{ qw(table quoter algorithm func crc_wid opt_slice) };

1;

# ###########################################################################
# End TableChecksum package
# ###########################################################################
