#!/usr/bin/perl -w

use strict;

use Test::More tests => 3;

use CPS qw( kwhile kforeach gkforeach );

sub callers
{
   my @pkgs;
   my $i = 1;
   push @pkgs, (caller $i)[3] and $i++ while (caller $i)[3];
   @pkgs;
}

my $count = 0;
my @callers;
kwhile( sub {
   my ( $knext, $klast ) = @_;
   push @callers, [ callers ];
   ++$count == 3 ? $klast->() : $knext->();
}, sub {} );

is_deeply( \@callers,
           [
              [ 'main::__ANON__', 'CPS::gkwhile' ],
              [ 'main::__ANON__', 'CPS::gkwhile' ],
              [ 'main::__ANON__', 'CPS::gkwhile' ],
           ],
           '@callers after kwhile' );

@callers = ();
kforeach( [ 1 .. 3 ], sub {
   my ( $i, $knext ) = @_;
   push @callers, [ callers ];
   $knext->();
}, sub {} );

is_deeply( \@callers,
           [
              [ 'main::__ANON__', 'CPS::gkwhile', 'CPS::gkforeach' ],
              [ 'main::__ANON__', 'CPS::gkwhile', 'CPS::gkforeach' ],
              [ 'main::__ANON__', 'CPS::gkwhile', 'CPS::gkforeach' ],
           ],
           '@callers after kforeach' );

my $gov = TestGovernor->new;

@callers = ();
gkforeach( $gov, [ 1 .. 3 ], sub {
   my ( $i, $knext ) = @_;
   push @callers, [ callers ];
   $knext->();
}, sub {} );

$gov->poke while $gov->pending;

is_deeply( \@callers,
           [
              [ 'main::__ANON__', 'CPS::gkwhile', 'CPS::gkforeach' ],
              [ 'main::__ANON__', 'CPS::gkwhile' ],
              [ 'main::__ANON__', 'CPS::gkwhile' ],
           ],
           '@callers after gkforeach on deferred governor' );

package TestGovernor;
use base qw( CPS::Governor );

sub again
{
   my $self = shift;
   my ( $code, @args ) = @_;
   $self->{code} = $code;
   $self->{args} = \@args;
}

sub pending
{
   my $self = shift;
   return defined $self->{code};
}

sub poke
{
   my $self = shift;

   my $code = delete $self->{code} or die;
   @_ = @{ delete $self->{args} };
   goto &$code;
}
