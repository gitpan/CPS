#!/usr/bin/perl -w

use strict;

use Test::More tests => 28;
use Test::Fatal;
use Test::Identity;
use Test::Refcount;

use CPS::Future;

{
   my $future = CPS::Future->new;

   ok( defined $future, '$future defined' );
   isa_ok( $future, "CPS::Future", '$future' );
   is_oneref( $future, '$future has refcount 1 initially' );

   ok( !$future->is_ready, '$future not yet ready' );

   my @on_ready_args;
   $future->on_ready( sub { @on_ready_args = @_ } );

   $future->done( result => "here" );

   is( scalar @on_ready_args, 1, 'on_ready passed 1 argument' );
   identical( $on_ready_args[0], $future, 'Future passed to on_ready' );
   undef @on_ready_args;

   ok( $future->is_ready, '$future is now ready' );
   is_deeply( [ $future->get ], [ result => "here" ], 'Results from $future->get' );

   is_oneref( $future, '$future has refcount 1 at end of test' );
}

{
   my $f1 = CPS::Future->new;
   my $f2 = CPS::Future->new;

   my $future = CPS::Future->wait_all( $f1, $f2 );
   # One ref in this $future lexical, one ref in the $self lexical shared by all
   # the child future's on_ready closures
   is_refcount( $future, 2, '$future of subs has refcount 2 initially' );

   my @on_ready_args;
   $future->on_ready( sub { @on_ready_args = @_ } );

   ok( !$future->is_ready, '$future of subs not yet ready' );
   is( scalar @on_ready_args, 0, 'on_ready of subs not yet invoked' );

   $f1->done( one => 1 );

   ok( !$future->is_ready, '$future of subs still not yet ready after f1 ready' );
   is( scalar @on_ready_args, 0, 'on_ready of subs not yet invoked' );

   $f2->done( two => 2 );

   is( scalar @on_ready_args, 1, 'on_ready of subs passed 1 argument' );
   identical( $on_ready_args[0], $future, 'Future passed to on_ready of subs' );
   undef @on_ready_args;

   ok( $future->is_ready, '$future of subs now ready after f2 ready' );
   my @results = $future->get;
   identical( $results[0], $f1, 'Results[0] from $future->get of subs is f1' );
   identical( $results[1], $f2, 'Results[1] from $future->get of subs is f2' );
   undef @results;

   is_refcount( $future, 1, '$future of subs has refcount 1 at end of test' );
   undef $future;

   is_refcount( $f1,   1, '$f1 of subs has refcount 1 at end of test' );
   is_refcount( $f2,   1, '$f2 of subs has refcount 1 at end of test' );
}

{
   my $f1 = CPS::Future->new;
   $f1->done;

   my $on_ready_called;
   $f1->on_ready( sub { $on_ready_called++ } );

   is( $on_ready_called, 1, 'on_ready called synchronously for already ready' );

   my $future = CPS::Future->wait_all( $f1 );

   ok( $future->is_ready, '$future of already-ready sub already ready' );
   my @results = $future->get;
   identical( $results[0], $f1, 'Results from $future->get of already ready' );
}

{
   my $future = CPS::Future->new;

   my $file = __FILE__;
   my $line = __LINE__+1;
   $future->fail( "Something broke" );

   ok( $future->is_ready, '$future->fail marks future ready' );

   is( $future->failure, "Something broke at $file line $line\n", '$future->failure yields exception' );
   is( exception { $future->get }, "Something broke at $file line $line\n", '$future->get throws exception' );
}
