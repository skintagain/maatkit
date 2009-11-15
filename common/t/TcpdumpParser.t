#!/usr/bin/perl

use strict;
use warnings FATAL => 'all';
use English qw(-no_match_vars);
use Test::More tests => 6;

use Data::Dumper;
$Data::Dumper::Quotekeys = 0;
$Data::Dumper::Sortkeys  = 1;
$Data::Dumper::Indent    = 1;

require "../TcpdumpParser.pm";

my $p = new TcpdumpParser();

# First, parse the TCP and IP packet...
my $contents = <<EOF;
2009-04-12 21:18:40.638244 IP 192.168.28.223.56462 > 192.168.28.213.mysql: tcp 301
\t0x0000:  4508 0161 7dc5 4000 4006 00c5 c0a8 1cdf
\t0x0010:  c0a8 1cd5 dc8e 0cea adc4 5111 ad6f 995e
\t0x0020:  8018 005b 0987 0000 0101 080a 62e6 32e7
\t0x0030:  62e4 a103 2901 0000 0353 454c 4543 5420
\t0x0040:  6469 7374 696e 6374 2074 702e 6964 2c20
\t0x0050:  7470 2e70 726f 6475 6374 5f69 6d61 6765
\t0x0060:  5f6c 696e 6b20 6173 2069 6d67 2c20 7470
\t0x0070:  2e69 6e6e 6572 5f76 6572 7365 3220 6173
\t0x0080:  2074 6974 6c65 2c20 7470 2e70 7269 6365
\t0x0090:  2046 524f 4d20 7470 726f 6475 6374 7320
\t0x00a0:  7470 2c20 6667 6966 745f 6c69 6e6b 2065
\t0x00b0:  2057 4845 5245 2074 702e 7072 6f64 7563
\t0x00c0:  745f 6465 7363 203d 2027 6667 6966 7427
\t0x00d0:  2041 4e44 2074 702e 6964 3d65 2e70 726f
\t0x00e0:  6475 6374 5f69 6420 2061 6e64 2074 702e
\t0x00f0:  7072 6f64 7563 745f 7374 6174 7573 3d35
\t0x0100:  2041 4e44 2065 2e63 6174 5f69 6420 696e
\t0x0110:  2028 322c 3131 2c2d 3129 2041 4e44 2074
\t0x0120:  702e 696e 7369 6465 5f69 6d61 6765 203d
\t0x0130:  2027 456e 676c 6973 6827 2020 4f52 4445
\t0x0140:  5220 4259 2074 702e 7072 696e 7461 626c
\t0x0150:  6520 6465 7363 204c 494d 4954 2030 2c20
\t0x0160:  38
EOF

is_deeply(
   $p->_parse_packet($contents),
   {  ts         => '2009-04-12 21:18:40.638244',
      seq        => '2915324177',
      ack        => '2909772126',
      src_host   => '192.168.28.223',
      src_port   =>  '56462',
      dst_host   => '192.168.28.213',
      dst_port   => '3306',
      complete   => 1,
      ip_hlen    => 5,
      tcp_hlen   => 8,
      dgram_len  => 353,
      data_len   => 301,
      syn        => 0,
      fin        => 0,
      rst        => 0,
      data => join('', qw(
         2901 0000 0353 454c 4543 5420
         6469 7374 696e 6374 2074 702e 6964 2c20
         7470 2e70 726f 6475 6374 5f69 6d61 6765
         5f6c 696e 6b20 6173 2069 6d67 2c20 7470
         2e69 6e6e 6572 5f76 6572 7365 3220 6173
         2074 6974 6c65 2c20 7470 2e70 7269 6365
         2046 524f 4d20 7470 726f 6475 6374 7320
         7470 2c20 6667 6966 745f 6c69 6e6b 2065
         2057 4845 5245 2074 702e 7072 6f64 7563
         745f 6465 7363 203d 2027 6667 6966 7427
         2041 4e44 2074 702e 6964 3d65 2e70 726f
         6475 6374 5f69 6420 2061 6e64 2074 702e
         7072 6f64 7563 745f 7374 6174 7573 3d35
         2041 4e44 2065 2e63 6174 5f69 6420 696e
         2028 322c 3131 2c2d 3129 2041 4e44 2074
         702e 696e 7369 6465 5f69 6d61 6765 203d
         2027 456e 676c 6973 6827 2020 4f52 4445
         5220 4259 2074 702e 7072 696e 7461 626c
         6520 6465 7363 204c 494d 4954 2030 2c20
         38)),
   },
   'Parsed packet OK');

my $oktorun = 1;

sub run_test {
   my ( $file, $desc, $result ) = @_;
   my @packets;
   open my $fh, '<', $file or BAIL_OUT("Cannot open $file: $OS_ERROR");
   while ( my $packet = $p->parse_event(fh=>$fh, oktorun=>sub { $oktorun=$_[0]; }) ) {
      push @packets, $packet;
   }

   # raw_packet is the actual dump text from the file.  It's used
   # in MySQLProtocolParser but I don't think we need to double-check
   # it here.  It will make the results very long.
   foreach my $packet ( @packets ) {
      delete $packet->{raw_packet};
   }

   if ( !is_deeply(
         \@packets,
         $result,
         "$file: $desc"
      ) ) {
      print Dumper(\@packets);
   }
   return;
}

# Check that parsing multiple packets and callback works.
run_test(
   'samples/tcpdump001.txt',
   'basic packets',
   [
      {  ts          => '2009-04-12 09:50:16.804849',
         ack         => '2903937561',
         seq         => '2894758931',
         src_host    => '127.0.0.1',
         src_port    => '42167',
         dst_host    => '127.0.0.1',
         dst_port    => '3306',
         complete    => 1,
         pos_in_log  => 0,
         ip_hlen     => 5,
         tcp_hlen    => 8,
         dgram_len   => 89,
         data_len    => 37,
         syn         => 0,
         fin         => 0,
         rst         => 0,
         data        => join('', qw(
            2100 0000 0373 656c 6563 7420
            2268 656c 6c6f 2077 6f72 6c64 2220 6173
            2067 7265 6574 696e 67)),
      },
      {  ts          => '2009-04-12 09:50:16.805123',
         ack         => '2894758968',
         seq         => '2903937561',
         src_host    => '127.0.0.1',
         src_port    => '3306',
         dst_host    => '127.0.0.1',
         dst_port    => '42167',
         complete    => 1,
         pos_in_log  => 355,
         ip_hlen     => 5,
         tcp_hlen    => 8,
         dgram_len   => 125,
         data_len    => 73,
         syn         => 0,
         fin         => 0,
         rst         => 0,
         data          => join('', qw(
            0100 0001 011e 0000 0203 6465
            6600 0000 0867 7265 6574 696e 6700 0c08
            000b 0000 00fd 0100 1f00 0005 0000 03fe
            0000 0200 0c00 0004 0b68 656c 6c6f 2077
            6f72 6c64 0500 0005 fe00 0002 00)),
      },
   ],
);

is(
   $oktorun,
   0,
   'Sets oktorun'
);

# #############################################################################
# Issue 544: memcached parse error: Use of uninitialized value in pattern match 
# #############################################################################

# This issue is caused by having extra info in the tcpdump output.
run_test(
   'samples/memc_tcpdump013.txt',
   'verbose tcpdump output with ascii dump',
   [
      {  ts          => '2009-08-03 19:56:37.683157',
         ack         => '1391934401',
         seq         => '1393769400',
         src_host    => '75.126.27.210',
         src_port    => '42819',
         dst_host    => '75.126.27.210',
         dst_port    => '11211',
         complete    => 1,
         pos_in_log  => 0,
         ip_hlen     => 5,
         tcp_hlen    => 5,
         dgram_len   => 66,
         data_len    => 26,
         syn         => 0,
         fin         => 0,
         rst         => 0,
         data        => join('', qw(
            6765 7420 323a 6f70 7469 6f6e 733a 616c 6c6f 7074 696f 6e73 0d0a
         )),
      },
   ],
);

# #############################################################################
# Issue 564: mk-query-digest --type tcpdump|memcached crashes on empty input
# #############################################################################
run_test(
   'samples/tcpdump020.txt',
   'Empty input (issue 564)',
   [
   ],
);

# #############################################################################
# Done.
# #############################################################################
my $output = '';
{
   local *STDERR;
   open STDERR, '>', \$output;
   $p->_d('Complete test coverage');
}
like(
   $output,
   qr/Complete test coverage/,
   '_d() works'
);

