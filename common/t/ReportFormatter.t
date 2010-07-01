#!/usr/bin/perl

BEGIN {
   die "The MAATKIT_WORKING_COPY environment variable is not set.  See http://code.google.com/p/maatkit/wiki/Testing"
      unless $ENV{MAATKIT_WORKING_COPY} && -d $ENV{MAATKIT_WORKING_COPY};
   unshift @INC, "$ENV{MAATKIT_WORKING_COPY}/common";
};

use strict;
use warnings FATAL => 'all';
use English qw(-no_match_vars);
use Test::More tests => 20;

use Transformers;
use ReportFormatter;
use MaatkitTest;

my $rf;

$rf = new ReportFormatter();

isa_ok($rf, 'ReportFormatter');

# #############################################################################
# truncate_value()
# #############################################################################
is(
   $rf->truncate_value(
      {truncate_mark=>'...', truncate_side=>'right'},
      "hello world",
      7,
   ),
   "hell...",
   "truncate_value(), right side"
);

is(
   $rf->truncate_value(
      {truncate_mark=>'...', truncate_side=>'left'},
      "hello world",
      7,
   ),
   "...orld",
   "truncate_value(), left side"
);

is(
   $rf->truncate_value(
      {truncate_mark=>'...', truncate_side=>'left'},
      "hello world",
      11,
   ),
   "hello world",
   "truncate_value(), max width == val width"
);

is(
   $rf->truncate_value(
      {truncate_mark=>'...', truncate_side=>'left'},
      "hello world",
      100,
   ),
   "hello world",
   "truncate_value(), max width > val width"
);

# #############################################################################
# Basic report.
# #############################################################################
$rf->set_title('Checksum differences');
$rf->set_columns(
   {
      name        => 'Query ID',
      width_fixed => length '0x234DDDAC43820481-3',
   },
   {
      name => 'db-1.foo.com',
   },
   {
      name => '123.123.123.123',
   },
);

$rf->add_line(qw(0x3A99CC42AEDCCFCD-1  ABC12345  ADD12345));
$rf->add_line(qw(0x234DDDAC43820481-3  0007C99B  BB008171));

is(
   $rf->get_report(),
"# Checksum differences
# Query ID             db-1.foo.com 123.123.123.123
# ==================== ============ ===============
# 0x3A99CC42AEDCCFCD-1 ABC12345     ADD12345
# 0x234DDDAC43820481-3 0007C99B     BB008171
",
   'Basic report'
);

# #############################################################################
# Header that's too wide.
# #############################################################################
$rf = new ReportFormatter();
$rf->set_columns(
   { name => 'We are very long header columns that are going to cause', },
   { name => 'this sub to die because together we cannot fit on one line' },
);
is(
   $rf->get_report(),
"# ...ader columns that are going to cause ...e together we cannot fit on one l
# ======================================= ====================================
",
   "Full auto-fit columns to line"
);

$rf = new ReportFormatter();
$rf->set_columns(
   {
      name      => 'We are very long header columns that are going to cause',
      width_pct => 40,
   },
   {
      name      => 'this sub to die because together we cannot fit on one line',
      width_pct => 60,
   },
);

is(
   $rf->get_report(),
"# ...umns that are going to cause ... because together we cannot fit on one li
# =============================== ============================================
",
   "Two fixed percentage-width columsn"
);

$rf = new ReportFormatter();
$rf->set_columns(
   {
      name  => 'header1',
      width => 7,
   },
   { name => 'this long line should take up the rest of the line.......!', },
);

is(
   $rf->get_report(),
"# header1 this long line should take up the rest of the line.......!
# ======= ====================================================================
",
   "One fixed char-width column and one auto-width column"
);

# #############################################################################
# Test that header underline respects line width.
# #############################################################################
$rf = new ReportFormatter();
$rf->set_columns(
   { name => 'col1' },
   { name => 'col2' },
);
$rf->add_line('short', 'long long long long long long long long long long long long long long long long long long');

is(
   $rf->get_report(),
"# col1  col2
# ===== ======================================================================
# short long long long long long long long long long long long long long lo...
",
   'Truncate header underlining to line width'
);

# #############################################################################
# Test taht header labels are always left justified.
# #############################################################################
$rf = new ReportFormatter();
$rf->set_columns(
   { name => 'Rank',          right_justify => 1, },
   { name => 'Query ID',                          },
   { name => 'Response time', right_justify => 1, },
   { name => 'Calls',         right_justify => 1, },
   { name => 'R/Call',        right_justify => 1, },
   { name => 'Item',                              },
);
$rf->add_line(
   '123456789', '0x31DA25F95494CA95', '0.1494 99.9%', '1', '0.1494', 'SHOW');

is(
   $rf->get_report(),
"# Rank      Query ID           Response time Calls R/Call Item
# ========= ================== ============= ===== ====== ====
# 123456789 0x31DA25F95494CA95  0.1494 99.9%     1 0.1494 SHOW
",
   'Header labels are always left justified'
);

# #############################################################################
# Respect line width.
# #############################################################################
$rf = new ReportFormatter();
$rf->set_title('Respect line width');
$rf->set_columns(
   { name => 'col1' },
   { name => 'col2' },
   { name => 'col3' },
);
$rf->add_line(
   'short',
   'longer',
   'long long long long long long long long long long long long long long long long long long'
);
$rf->add_line(
   'a',
   'b',
   'c',
);

is(
   $rf->get_report(),
"# Respect line width
# col1  col2   col3
# ===== ====== ===============================================================
# short longer long long long long long long long long long long long long ...
# a     b      c
",
   'Respects line length'
);

# #############################################################################
# extend_right
# #############################################################################
$rf = new ReportFormatter(extend_right=>1);
$rf->set_title('extend_right');
$rf->set_columns(
   { name => 'col1' },
   { name => 'col2' },
   { name => 'col3' },
);
$rf->add_line(
   'short',
   'longer',
   'long long long long long long long long long long long long long long long long long long'
);
$rf->add_line(
   'a',
   'b',
   'c',
);

is(
   $rf->get_report(),
"# extend_right
# col1  col2   col3
# ===== ====== ===============================================================
# short longer long long long long long long long long long long long long long long long long long long
# a     b      c
",
   "Allow right-most column to extend beyond line width"
);

# #############################################################################
# Relvative column widths.
# #############################################################################
$rf = new ReportFormatter();
$rf->set_title('Relative col widths');
$rf->set_columns(
   { name => 'col1', width_pct=>'20', },
   { name => 'col2', width_pct=>'40', },
   { name => 'col3', width_pct=>'40',  },
);
$rf->add_line(
   'shortest',
   'a b c d e f g h i j k l m n o p',
   'seoncd longest line',
);
$rf->add_line(
   'x',
   'y',
   'z',
);

is(
   $rf->get_report(),
"# Relative col widths
# col1            col2                            col3
# =============== =============================== ============================
# shortest        a b c d e f g h i j k l m n o p seoncd longest line
# x               y                               z
",
   "Relative col widths that fit"
);

$rf = new ReportFormatter();
$rf->set_title('Relative col widths');
$rf->set_columns(
   { name => 'col1', width_pct=>'20', },
   { name => 'col2', width_pct=>'40', },
   { name => 'col3', width_pct=>'40',  },
);
$rf->add_line(
   'shortest',
   'a b c d e f g h i j k l m n o p',
   'seoncd longest line',
);
$rf->add_line(
   'x',
   'y',
   'z',
);
$rf->add_line(
   'this line is going to have to be truncated because it is too long',
   'this line is ok',
   'and this line will have to be truncated, too',
);

is(
   $rf->get_report(),
"# Relative col widths
# col1            col2                            col3
# =============== =============================== ============================
# shortest        a b c d e f g h i j k l m n o p seoncd longest line
# x               y                               z
# this line is... this line is ok                 and this line will have t...
",
   "Relative columns made smaller to fit"
);

$rf = new ReportFormatter();
$rf->set_title('Relative col widths');
$rf->set_columns(
   { name => 'col1', width    =>'25', },
   { name => 'col2', width_pct=>'33', },
   { name => 'col3', width_pct=>'33', },
);
$rf->add_line(
   'shortest',
   'a b c d e f g h i j k l m n o p',
   'seoncd longest line',
);
$rf->add_line(
   'x',
   'y',
   'z',
);
$rf->add_line(
   '1234567890123456789012345xxxxxx',
   'this line is ok',
   'and this line will have to be truncated, too',
);

is(
   $rf->get_report(),
"# Relative col widths
# col1                      col2                      col3
# ========================= ========================= ========================
# shortest                  a b c d e f g h i j k ... seoncd longest line
# x                         y                         z
# 1234567890123456789012... this line is ok           and this line will ha...
",
   "Fixed and relative columns"
);


$rf = new ReportFormatter();
$rf->set_title('Short cols');
$rf->set_columns(
   { name => 'I am column1', },
   { name => 'I am column2', },
   { name => "I don't know who I am", },
);
$rf->add_line(
   '',
   '',
   '',
);

is(
   $rf->get_report(),
"# Short cols
# I am column1              I am column2              I don't know who I am
# ========================= ========================= ========================
#                                                     
",
   "Short columsn, blank data"
);

$rf = new ReportFormatter();
$rf->set_title('Short cols');
$rf->set_columns(
   { name => 'I am column1', },
   { name => 'I am column2', },
   { name => "I don't know who I am", },
);
$rf->add_line(undef,undef,undef);

is(
   $rf->get_report(),
"# Short cols
# I am column1              I am column2              I don't know who I am
# ========================= ========================= ========================
#                                                     
",
   "Short columsn, undef data"
);

$rf = new ReportFormatter();
$rf->set_title('Short cols');
$rf->set_columns(
   { name => 'I am column1', },
   { name => 'I am column2', },
   { name => "I don't know who I am", },
);
$rf->add_line('','','');
$rf->add_line(qw(a b c));

is(
   $rf->get_report(),
"# Short cols
# I am column1 I am column2 I don't know who I am
# ============ ============ =====================
#                           
# a            b            c
",
   "Short columsn, blank and short data"
);

# #############################################################################
# Done.
# #############################################################################
my $output = '';
{
   local *STDERR;
   open STDERR, '>', \$output;
   $rf->_d('Complete test coverage');
}
like(
   $output,
   qr/Complete test coverage/,
   '_d() works'
);
exit;
