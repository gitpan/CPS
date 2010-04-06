#!/usr/bin/perl -w

use strict;

use Test::More tests => 7;

use CPS qw( kwhile );

my $poke;

my @nums;

my $num = 1;

kwhile(
   sub {
      my ( $knext, $klast ) = @_;

      push @nums, $num;
      $num++;

      $poke = ( $num == 3 ) ? $klast : $knext;
   },
   sub {
      push @nums, "finished";
   },
);

is_deeply( \@nums, [ 1 ], 'kwhile async - @nums initially' );
$poke->();
is_deeply( \@nums, [ 1, 2 ], 'kwhile async - @nums after first poke' );
$poke->();
is_deeply( \@nums, [ 1, 2, "finished" ], 'kwhile async - @nums after second poke' );

@nums = ();

our $nested = 0;

kwhile(
   sub {
      my ( $knext, $klast ) = @_;

      is( $nested, 0, "kwhile sync call does not nest for $num" );

      local $nested = 1;

      push @nums, $num;
      $num++;

      ( ( $num == 5 ) ? $klast : $knext )->();
   },
   sub {
      push @nums, "finished";
   },
);

is_deeply( \@nums, [ 3, 4, "finished" ], 'kwhile sync - @nums initially' );

my @result;
kwhile(
   sub {
      my ( $knext, $klast ) = @_;
      $klast->( 1, 2, 3 );
   },
   sub {
      push @result, @_;
   }
);

is_deeply( \@result, [], 'kwhile clears @_ in $klast' );
