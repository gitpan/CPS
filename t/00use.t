#!/usr/bin/perl

use Test::More tests => 4;

use_ok( 'CPS' );
use_ok( 'CPS::Governor' );

use_ok( 'CPS::Governor::Simple' );
use_ok( 'CPS::Governor::Deferred' );
