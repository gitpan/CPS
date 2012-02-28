#!/usr/bin/perl -w

use strict;

use Test::More tests => 6;

my $warnings;
my $warnline;
{
   local $SIG{__WARN__} = sub { $warnings .= join "", @_ };

   require CPS;

   $warnline = __LINE__+1;
   CPS->import(qw( kwhile kmap kgrep kfoldl kgenerate ));
}

# Carp 1.25 added a period at the end of the message, to match core's die()
my $re = <<"EOF";
Legacy import of kmap; use CPS::Functional 'kmap' instead at \Q$0\E line $warnline\.?
Legacy import of kgrep; use CPS::Functional 'kgrep' instead at \Q$0\E line $warnline\.?
Legacy import of kfoldl; use CPS::Functional 'kfoldl' instead at \Q$0\E line $warnline\.?
Legacy import of kgenerate; use CPS::Functional 'kunfold' instead at \Q$0\E line $warnline\.?
EOF
like( $warnings, qr/^$re$/, 'Import warnings' );

my @ret;

my $i = 0;
kwhile(
   sub { $i++; ( $i == 5 ? $_[1] : $_[0] )->() },
   sub {},
);
is( $i, 5, 'kwhile' );

kmap(
   [qw( a b c )],
   sub { $_[-1]->( uc $_[0] ) },
   sub { @ret = @_ },
);
is_deeply( \@ret, [qw( A B C )], 'kmap' );

kgrep(
   [ 1, 2, 3, 4 ],
   sub { $_[-1]->( $_[0] % 2 == 0 ) },
   sub { @ret = @_ },
);
is_deeply( \@ret, [ 2, 4 ], 'kgrep' );

kfoldl(
   [ 1, 2, 3, 4 ],
   sub { $_[-1]->( $_[0] + $_[1] ) },
   sub { @ret = @_ },
);
is_deeply( \@ret, [ 10 ], 'kfoldl' );

kgenerate(
   "hello world",
   sub { $_[0] =~ s/^(\S+)\s*// ? $_[-2]->( $_[0], $1 ) : $_[-1]->() },
   sub { @ret = @_ },
);
is_deeply( \@ret, [ "hello", "world" ], 'kgenerate' );
