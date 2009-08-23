# This program is copyright 2009-@CURRENTYEAR@ Percona Inc.
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
# QueryExecutor package $Revision$
# ###########################################################################
package QueryExecutor;

use strict;
use warnings FATAL => 'all';

use English qw(-no_match_vars);
use Time::HiRes qw(time);
use Data::Dumper;
$Data::Dumper::Indent    = 1;
$Data::Dumper::Sortkeys  = 1;
$Data::Dumper::Quotekeys = 0;

use constant MKDEBUG => $ENV{MKDEBUG};

sub new {
   my ( $class, %args ) = @_;
   foreach my $arg ( qw() ) {
      die "I need a $arg argument" unless $args{$arg};
   }
   my $self = {};
   return bless $self, $class;
}

# Executes a query on the given hosts, calling an array of callbacks for
# each host.  The idea is to collect results from various operations pertaining
# to the same query when ran on multiple hosts.  For example, the most basic
# operation called Query_time times how long the query takes to execute.  Other
# operations do things like check for warnings after execution.
#
# Each operation is performed via a callback and is expected to return a
# key=>value pair where the key is the name of the operation and the value
# is the operation's results.  The results are a hashref with other
# operation-specific key=>value pairs; there should always be at least an
# error key that is undef for no error or a string saying what failed and
# possibly also an errors key that is an arrayref of strings with more
# specific errors if lots of things failed.
#
# All callbacks are passed the query, the current host's dbh, dsn and name,
# and the results from preceding operations.  Each callback is expected to
# handle its own errors, so do not die inside a callback!
#
# All callbacks are ran no matter what.  But since each callback gets the
# results off prior callbacks, you can fail gracefully in a callback by looking
# to see if some expected prior callback had an error or not.  So the important
# point for callbacks is: NEVER ASSUME SUCCESS AND NEVER FAIL SILENTLY.
#
# In fact, operations are checked and if something looks amiss, the module
# will complain and die loudly.
#
# Obviously, one callback should actually execute the query.  The Query_time
# sub is provided for you which does this, or you can use your own sub.
# Other common callbacks/operations provided in this package:
#   get_warnings(), clear_warnings(), checksum_results().
#
# Required arguments:
#   * query                The query to execute
#   * callbacks            Arrayref of callback subs
#   * hosts                Arrayref of hosts, each of which is a hashref like:
#       {
#         dbh              (req) Already connected DBH
#         dsn              DSN for more verbose debug messages
#       }
# Optional arguments:
#   * DSNParser            DSNParser obj in case any host dsns are given
#
sub exec {
   my ( $self, %args ) = @_;
   foreach my $arg ( qw(query hosts callbacks) ) {
      die "I need a $arg argument" unless $args{$arg};
   }
   my $query      = $args{query};
   my $callbacks  = $args{callbacks};
   my $hosts      = $args{hosts};
   my $dp         = $args{DSNParser};

   MKDEBUG && _d('Executing query:', $query);

   my @results;
   my $hostno = -1;
   HOST:
   foreach my $host ( @$hosts ) {
      $hostno++;  # Increment this now because we might not reach loop's end.
      $results[$hostno] = {};
      my $results       = $results[$hostno];
      my $dbh           = $host->{dbh};
      my $dsn           = $host->{dsn};
      my $host_name     = $dp && $dsn ? $dp->as_string($dsn) : $hostno + 1;
      my %callback_args = (
         query     => $query,
         dbh       => $dbh,
         dsn       => $dsn,
         host_name => $host_name,
         results   => $results,
      );

      MKDEBUG && _d('Starting execution on host', $host_name);
      foreach my $callback ( @$callbacks ) {
         my ($name, $res);
         eval {
            ($name, $res) = $callback->(%callback_args);
         };
         if ( $EVAL_ERROR ) {
            # This shouldn't happen, but in case of a bad callback...
            __die(
               "A callback sub had an unhandled error: $EVAL_ERROR",
               $name,
               $res,
               $host_name,
               \@results
            );
         };
         _check_results($name, $res, $host_name, \@results);
         $results->{$name} = $res;
      }
      MKDEBUG && _d('Results for host', $host_name, ':', Dumper($results));
   } # HOST

   return @results;
}

sub Query_time {
   my ( $self, %args ) = @_;
   foreach my $arg ( qw(query dbh) ) {
      die "I need a $arg argument" unless $args{$arg};
   }
   my $query = $args{query};
   my $dbh   = $args{dbh};
   my $error = undef;
   my $name  = 'Query_time';
   my $res   = { error => undef, Query_time => -1, };
   MKDEBUG && _d($name);

   my ( $start, $end, $query_time );
   eval {
      $start = time();
      $dbh->do($query);
      $end   = time();
      $query_time = sprintf '%.6f', $end - $start;
   };
   if ( $EVAL_ERROR ) {
      MKDEBUG && _d('Error executing query on host', $args{host_name}, ':',
         $EVAL_ERROR);
      $res->{error} = $EVAL_ERROR;
   }
   else {
      $res->{Query_time} = $query_time;
   }

   return $name, $res;
}

# Returns an array with its name and a hashref with warnings/errors:
# (
#   warnings,
#   {
#     error => undef|string,
#     count => 3,         # @@warning_count,
#     codes => {          # SHOW WARNINGS
#       1062 => {
#         Level   => "Error",
#         Code    => "1062",
#         Message => "Duplicate entry '1' for key 1",
#       }
#     },
#   }
# )
sub get_warnings {
   my ( $self, %args ) = @_;
   foreach my $arg ( qw(dbh) ) {
      die "I need a $arg argument" unless $args{$arg};
   }
   my $dbh   = $args{dbh};
   my $error = undef;
   my $name  = 'warnings';
   MKDEBUG && _d($name);

   my $warnings;
   my $warning_count;
   eval {
      $warnings      = $dbh->selectall_hashref('SHOW WARNINGS', 'Code');
      $warning_count = $dbh->selectall_arrayref('SELECT @@warning_count',
         { Slice => {} });
   };
   if ( $EVAL_ERROR ) {
      MKDEBUG && _d('Error getting warnings:', $EVAL_ERROR);
      $error = $EVAL_ERROR;
   }

   my $results = {
      error => $error,
      codes => $warnings,
      count => $warning_count->[0]->{'@@warning_count'} || 0,
   };
   return $name, $results;
}

sub clear_warnings {
   my ( $self, %args ) = @_;
   foreach my $arg ( qw(dbh query QueryParser) ) {
      die "I need a $arg argument" unless $args{$arg};
   }
   my $dbh     = $args{dbh};
   my $query   = $args{query};
   my $qparser = $args{QueryParser};
   my $error   = undef;
   my $name    = 'clear_warnings';
   MKDEBUG && _d($name);

   # On some systems, MySQL doesn't always clear the warnings list
   # after a good query.  This causes good queries to show warnings
   # from previous bad queries.  A work-around/hack is to
   # SELECT * FROM table LIMIT 0 which seems to always clear warnings.
   my @tables = $qparser->get_tables($query);
   if ( @tables ) {
      MKDEBUG && _d('tables:', @tables);
      my $sql = "SELECT * FROM $tables[0] LIMIT 0";
      MKDEBUG && _d($sql);
      eval {
         $dbh->do($sql);
      };
      if ( $EVAL_ERROR ) {
         MKDEBUG && _d('Error clearning warnings:', $EVAL_ERROR);
         $error = $EVAL_ERROR;
      }
   }
   else {
      $error = "Cannot clear warnings because the tables for this query cannot "
         . "be parsed.";
   }

   return $name, { error=>$error };
}

# This sub and checksum_results() require that you append
# "CREATE TEMPORARY TABLE database.tmp_table AS" to the query before
# calling exec().  This sub drops an old tmp table if it exists,
# and sets the default storage engine to MyISAM.
sub pre_checksum_results {
   my ( $self, %args ) = @_;
   foreach my $arg ( qw(dbh database tmp_table Quoter) ) {
      die "I need a $arg argument" unless $args{$arg};
   }
   my $dbh     = $args{dbh};
   my $db      = $args{database};
   my $tmp_tbl = $args{tmp_table};
   my $q       = $args{Quoter};
   my $error   = undef;
   my $name    = 'pre_checksum_results';
   MKDEBUG && _d($name);

   my $tmp_db_tbl = $q->quote($db, $tmp_tbl);
   eval {
      $dbh->do("DROP TABLE IF EXISTS $tmp_db_tbl");
      $dbh->do("SET storage_engine=MyISAM");
   };
   if ( $EVAL_ERROR ) {
      MKDEBUG && _d('Error dropping table', $tmp_db_tbl, ':', $EVAL_ERROR);
      $error = $EVAL_ERROR;
   }
   return $name, { error=>$error };
}

# Either call pre_check_results() as a pre-exec callback to exec() or
# do what it does manually before calling this sub as a post-exec callback.
# This sub checksums the tmp table created when the query was executed
# with "CREATE TEMPORARY TABLE database.tmp_table AS" alreay appended to it.
# Since a lot can go wrong in this operation, the returned error will be the
# last error and errors will have all errors.
sub checksum_results {
   my ( $self, %args ) = @_;
   foreach my $arg ( qw(dbh database tmp_table MySQLDump TableParser Quoter) ) {
      die "I need a $arg argument" unless $args{$arg};
   }
   my $dbh     = $args{dbh};
   my $db      = $args{database};
   my $tmp_tbl = $args{tmp_table};
   my $du      = $args{MySQLDump};
   my $tp      = $args{TableParser};
   my $q       = $args{Quoter};
   my $error   = undef;
   my @errors  = ();
   my $name    = 'checksum_results';
   MKDEBUG && _d($name);

   my $tmp_db_tbl = $q->quote($db, $tmp_tbl);
   my $tbl_checksum;
   my $n_rows;
   my $tbl_struct;
   eval {
      $n_rows = $dbh->selectall_arrayref("SELECT COUNT(*) FROM $tmp_db_tbl")->[0]->[0];
      $tbl_checksum = $dbh->selectall_arrayref("CHECKSUM TABLE $tmp_db_tbl")->[0]->[1];
   };
   if ( $EVAL_ERROR ) {
      MKDEBUG && _d('Error counting rows or checksumming', $tmp_db_tbl, ':',
         $EVAL_ERROR);
      $error = $EVAL_ERROR;
      push @errors, $error;
   }
   else {
      # Parse the tmp table's struct.
      eval {
         my $ddl = $du->get_create_table($dbh, $q, $db, $tmp_tbl);
         MKDEBUG && _d('tmp table ddl:', Dumper($ddl));
         if ( $ddl->[0] eq 'table' ) {
            $tbl_struct = $tp->parse($ddl)
         }
      };
      if ( $EVAL_ERROR ) {
         MKDEBUG && _d('Failed to parse', $tmp_db_tbl, ':', $EVAL_ERROR); 
         $error = $EVAL_ERROR;
         push @errors, $error;
      }
   }

   # Event if CHECKSUM TABLE or parsing the tmp table fails, let's try
   # to drop the tmp table so we don't waste space.
   my $sql = "DROP TABLE IF EXISTS $tmp_db_tbl";
   MKDEBUG && _d($sql);
   eval { $dbh->do($sql); };
   if ( $EVAL_ERROR ) {
      MKDEBUG && _d('Error dropping tmp table:', $EVAL_ERROR);
      $error = $EVAL_ERROR;
      push @errors, $error;
   }

   # These errors are more important so save them till the end in case
   # someone only looks at the last error and not all errors.
   if ( !defined $n_rows ) { # 0 rows returned is ok.
      $error = "SELECT COUNT(*) for getting the number of rows didn't return a value";
      push @errors, $error;
      MKDEBUG && _d($error);
   }
   if ( !$tbl_checksum ) {
      $error = "CHECKSUM TABLE didn't return a value";
      push @errors, $error;
      MKDEBUG && _d($error);
   }

   # Avoid redundant error reporting.
   @errors = () if @errors == 1;

   my $results = {
      error        => $error,
      errors       => \@errors,
      checksum     => $tbl_checksum || 0,
      n_rows       => $n_rows || 0,
      table_struct => $tbl_struct,
   };
   return $name, $results;
}


# get_row_sths() implements part of an idea discussed by Mark Callaghan,
# Baron Schwartz and Daniel Nichter.  See:
# http://groups.google.com/group/maatkit-discuss/browse_thread/thread/5d0f208f4e76ec0f 
# http://groups.google.com/group/maatkit-discuss/browse_thread/thread/49f4564111c78a2f

# The big picture is to execute the query, simultaneously write its rows to
# an outfile and compare them with MockSyncStream.  If no differences are
# found, all is well.  If a difference is found, we stop comparing, write all
# rows to an outfile and later mk_upgrade::diff_rows() will handle the rest.
# For now, however, we just get a statement handle for the executed query
# because QueryExecutor does hosts one-by-one but we need two sths at once.
# See mk_upgrade::rank_row_sths() for how these sths are ranked/compared.
sub get_row_sths {
   my ( $self, %args ) = @_;
   foreach my $arg ( qw(query dbh) ) {
      die "I need a $arg argument" unless $args{$arg};
   }
   my $query      = $args{query};
   my $dbh        = $args{dbh};
   my $error      = undef;
   my $name       = 'get_row_sths';
   my $Query_time = { error => undef, Query_time => -1, };
   my ( $start, $end, $query_time );
   MKDEBUG && _d($name);

   my $sth;
   eval {
      $sth = $dbh->prepare($query);
   };
   if ( $EVAL_ERROR ) {
      MKDEBUG && _d('Error on prepare:', $EVAL_ERROR);
      $error = $EVAL_ERROR;
   }
   else {
      eval {
         $start = time();
         $sth->execute();
         $end   = time();
         $query_time = sprintf '%.6f', $end - $start;
      };
      if ( $EVAL_ERROR ) {
         MKDEBUG && _d('Error on execute:', $EVAL_ERROR);
         $error = $EVAL_ERROR;
         $Query_time->{error} = $error;
      }
      else {
         $Query_time->{Query_time} = $query_time;
      }
   }

   my $results = {
      error      => $error,
      sth        => $error ? undef : $sth,  # Only pass sth if no errors.
      Query_time => $Query_time,
   };
   return $name, $results;
}

sub _check_results {
   my ( $name, $res, $host_name, $all_res ) = @_;
   __die('Operation did not return a name!', @_)
      unless $name;
   __die('Operation did not return any results!', @_)
      unless $res || (scalar keys %$res);
   __die("Operation results do no have an 'error' key")
      unless exists $res->{error};
   __die("Operation error is blank string!")
      if defined $res->{error} && !$res->{error};
   __die("Operation errors is not an arrayref!")
      if $res->{errors} && ref $res->{errors} ne 'ARRAY';
   return;
}

# Die and print helpful info about what was going on
# at the time of our death.
sub __die {
   my ( $msg, $name, $res, $host_name, $all_res ) = @_;
   die "$msg\n"
      . "Host name: " . ($host_name ? $host_name : 'UNKNOWN') . "\n"
      . "Current results: " . Dumper($res)
      . "Prior results: "   . Dumper($all_res)
}

sub _d {
   my ($package, undef, $line) = caller 0;
   @_ = map { (my $temp = $_) =~ s/\n/\n# /g; $temp; }
        map { defined $_ ? $_ : 'undef' }
        @_;
   print STDERR "# $package:$line $PID ", join(' ', @_), "\n";
}

1;

# ###########################################################################
# End QueryExecutor package
# ###########################################################################
