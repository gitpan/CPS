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

is( $warnings, <<"EOF", 'Import warnings' );
Legacy import of kmap; use CPS::Functional 'kmap' instead at $0 line $warnline
Legacy import of kgrep; use CPS::Functional 'kgrep' instead at $0 line $warnline
Legacy import of kfoldl; use CPS::Functional 'kfoldl' instead at $0 line $warnline
Legacy import of kgenerate; use CPS::Functional 'kunfold' instead at $0 line $warnline
EOF

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
