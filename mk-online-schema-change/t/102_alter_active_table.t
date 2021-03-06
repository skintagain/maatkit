#!/usr/bin/env perl

BEGIN {
   die "The MAATKIT_WORKING_COPY environment variable is not set.  See http://code.google.com/p/maatkit/wiki/Testing"
      unless $ENV{MAATKIT_WORKING_COPY} && -d $ENV{MAATKIT_WORKING_COPY};
   unshift @INC, "$ENV{MAATKIT_WORKING_COPY}/common";
};

use strict;
use warnings FATAL => 'all';
use English qw(-no_match_vars);
use Test::More;

use MaatkitTest;
use Sandbox;
use Time::HiRes qw(usleep);
use Data::Dumper;
$Data::Dumper::Indent    = 1;
$Data::Dumper::Sortkeys  = 1;
$Data::Dumper::Quotekeys = 0;
require "$trunk/mk-online-schema-change/mk-online-schema-change";

my $dp  = new DSNParser(opts=>$dsn_opts);
my $sb  = new Sandbox(basedir => '/tmp', DSNParser => $dp);
my $dbh = $sb->get_dbh_for('master');

if ( !$dbh ) {
   plan skip_all => 'Cannot connect to sandbox master';
}
else {
   plan tests => 7;
}

my $output  = "";
my $cnf     = '/tmp/12345/my.sandbox.cnf';
my @args    = ('-F', $cnf);
my $exit    = 0;
my $rows;

my $query_table_stop   = '/tmp/query_table.stop';
my $query_table_output = '/tmp/query_table.output';
diag(`rm -rf $query_table_stop`);
diag(`rm -rf $query_table_output`);

sub start_query_table {
   my ($db, $tbl, $pkcol) = @_;

   diag(`rm -rf $query_table_stop`);
   diag(`echo > $query_table_output`);

   my $cmd = "$trunk/mk-online-schema-change/t/samples/query_table.pl";
   system("$cmd 127.1 12345 $db $tbl $pkcol >$query_table_output &");

   return;
}

sub stop_query_table {
   diag(`touch $query_table_stop`);
   sleep 1;
   return;
}

sub get_ids { 
   open my $fh, '<', $query_table_output
      or die "Cannot open $query_table_output: $OS_ERROR";
   my @lines = <$fh>;
   close $fh;

   my %ids;
   foreach my $line ( @lines ) {
      my ($stmt, $ids) = split(':', $line);
      chomp $ids;
      $ids{$stmt} = $ids;
   }

   return \%ids;
};

sub check_ids {
   my ( $db, $tbl, $pkcol, $ids ) = @_;
   my $rows;

   my $n_updated  = $ids->{updated} ? ($ids->{updated}  =~ tr/,//) : 0;
   my $n_deleted  = $ids->{deleted} ? ($ids->{deleted}  =~ tr/,//) : 0;
   my $n_inserted = ($ids->{inserted} =~ tr/,//);

   # "1,1"=~tr/,// returns 1 but is 2 values
   $n_updated++ if $n_updated;
   $n_deleted++ if $n_deleted;
   $n_inserted++;

   $rows = $dbh->selectrow_arrayref(
      "SELECT COUNT($pkcol) FROM $db.$tbl");
   is(
      $rows->[0],
      500 + $n_inserted - $n_deleted,
      "New table row count: 500 original + $n_inserted inserted - $n_deleted deleted"
   ) or print Dumper($rows);

   $rows = $dbh->selectall_arrayref(
      "SELECT $pkcol FROM $db.$tbl WHERE $pkcol > 500 AND $pkcol NOT IN ($ids->{inserted})");
   is_deeply(
      $rows,
      [],
      "No extra rows inserted in new table"
   ) or print Dumper($rows);

   if ( $n_deleted ) {
      $rows = $dbh->selectall_arrayref(
         "SELECT $pkcol FROM $db.$tbl WHERE $pkcol IN ($ids->{deleted})");
      is_deeply(
         $rows,
         [],
         "No deleted rows present in new table"
      ) or print Dumper($rows);
   }
   else {
      ok(
         1,
         "No rows deleted"
      );
   };

   if ( $n_updated ) {
      $rows = $dbh->selectall_arrayref(
         "SELECT $pkcol FROM $db.$tbl WHERE $pkcol IN ($ids->{updated}) "
         . "AND c <> 'updated'");
      is_deeply(
         $rows,
         [],
         "Updated rows correct in new table"
      ) or print Dumper($rows);
   }
   else {
      ok(
         1,
         "No rows updated"
      );
   }

   return;
}
   
# #############################################################################
# Attempt to alter a table while another process is changing it.
# #############################################################################
$sb->load_file('master', "mk-online-schema-change/t/samples/small_table.sql");
$dbh->do('use mkosc');
$dbh->do('truncate table a');
diag(`cp $trunk/mk-online-schema-change/t/samples/a.outfile /tmp/`);
$dbh->do("load data local infile '/tmp/a.outfile' into table mkosc.a");
diag(`rm -rf /tmp/a.outfile`);

start_query_table(qw(mkosc a i));
$output = output(
   sub { $exit = mk_online_schema_change::main(@args,
      qw(--chunk-size 100),
      'D=mkosc,t=a', qw(--alter-new-table ENGINE=InnoDB --drop-old-table)) },
);
stop_query_table();

$rows = $dbh->selectall_hashref('show table status from mkosc', 'name');
is(
   $rows->{a}->{engine},
   'InnoDB',
   "New table ENGINE=InnoDB"
);

is(
   scalar keys %$rows,
   1,
   "Dropped old table"
);

is(
   $exit,
   0,
   "Exit status 0"
);

check_ids('mkosc', 'a', 'i', get_ids());

# ############################################################################
# Alter an active table with foreign keys.
# ############################################################################


# #############################################################################
# Done.
# #############################################################################
diag(`rm -rf $query_table_stop`);
#diag(`echo > $query_table_output`);
#$sb->wipe_clean($dbh);
exit;
