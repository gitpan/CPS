#!/usr/bin/perl -w

use strict;

use Test::More tests => 4;

use CPS::Governor::Simple;

my $gov = CPS::Governor::Simple->new;

ok( defined $gov, 'defined $gov' );
isa_ok( $gov, "CPS::Governor", '$gov' );

my $called = 0;
$gov->again( sub { $called = 1 } );

is( $called, 1, '$called is 1 after $gov->again' );

$gov->again( sub { $called = shift }, 3 );

is( $called, 3, '$called is 3 after $gov->again with arguments' );
