#  You may distribute under the terms of either the GNU General Public License
#  or the Artistic License (the same terms as Perl itself)
#
#  (C) Paul Evans, 2008,2009 -- leonerd@leonerd.org.uk

package CPS;

use strict;

our $VERSION = '0.02';

use Carp;

use Scalar::Util qw( weaken );

use base qw( Exporter );

our @EXPORT_OK = qw(
   kwhile
   kforeach
   kmap
   kgrep
   kfoldl
   kfoldr
   kgenerate

   liftk
);

=head1 NAME

C<CPS> - flow control structures in Continuation-Passing Style

=head1 OVERVIEW

The functions in this module implement or assist the writing of programs, or
parts of them, in Continuation Passing Style (CPS). Briefly, CPS is a style
of writing code where the normal call/return mechanism is replaced by explicit
"continuations", values passed in to functions which they should invoke, to
implement return behaviour. For more detail on CPS, see the SEE ALSO section.

What this module implements is not in fact true CPS, as Perl does not natively
support the idea of a real continuation (such as is created by a co-routine).
Furthermore, for CPS to be efficient in languages that natively support it,
their runtimes typically implement a lot of optimisation of CPS code, which
the Perl interpreter would be unable to perform. Instead, CODE references are
passed around to stand in their place. While not particularly useful for most
regular cases, this becomes very useful whenever some form of asynchronous or
event-based programming is being used. Continuations passed in to the body
function of a control structure can be stored in the event handlers of the
asynchronous or event-driven framework, so that when they are invoked later,
the code continues, eventually arriving at its final answer at some point in
the future.

In order for these examples to make sense, a fictional and simple
asynchronisation framework has been invented. The exact details of operation
should not be important, as it simply stands to illustrate the point. I hope
its general intention should be obvious. :)

 read_stdin_line( \&on_line ); # wait on a line from STDIN, then pass it
                               # to the handler function

=head1 SYNOPSIS

 use CPS qw( kwhile );

 kwhile( sub {
    my ( $knext, $klast ) = @_;

    print "Enter a number, or q to quit: ";

    read_stdin_line( sub {
       my ( $first ) = @_;
       chomp $first;

       return $klast->() if $first eq "q";

       print "Enter a second number: ";

       read_stdin_line( sub {
          my ( $second ) = @_;

          print "The sum is " . ( $first + $second ) . "\n";

          $knext->();
       } );
    } );
 },
 sub { exit }
 );

=cut

=head1 FUNCTIONS

In all of the following functions, the C<\&body> function can provide results
by invoking its continuation / one of its continuations, either synchronously
or asynchronously at some point later (via some event handling or other
mechanism); the next invocation of C<\&body> will not take place until the
previous one exits if it is done synchronously.

They all take the prefix C<k> before the name of the regular perl keyword or
function they aim to replace. It is common in CPS code in other languages,
such as Scheme or Haskell, to store a continuation in a variable called C<k>.
This convention is followed here.

=cut

=head2 kwhile( \&body, $k )

CPS version of perl's C<while> loop. Repeatedly calls the C<body> code until
it indicates the end of the loop, then invoke C<$k>.

 $body->( $knext, $klast )
    $knext->()
    $klast->()

 $k->()

If C<$knext> is invoked, the body will be called again. If C<$klast> is
invoked, the continuation C<$k> is invoked.

=cut

sub kwhile
{
   my ( $body, $k ) = @_;

   ref $body eq "CODE" or croak 'Expected $body as CODE ref';
   ref $k  eq "CODE" or croak 'Expected $k as CODE ref';

   my $sync;
   my $again = 0;

   my $iter; $iter = sub {
      my $knext = $iter;

      $sync = 1;
      $body->(
         sub { $sync ? $again=1 : goto &$knext },
         $k,
      );
      $sync = 0;

      if( $again ) {
         $again = 0;
         goto &$knext; # tailcall
      }
   };

   my $kfirst = $iter;
   weaken( $iter );

   goto &$kfirst;
}

=head2 kforeach( \@items, \&body, $k )

CPS version of perl's C<foreach> loop. Calls the C<body> code once for each
element in C<@items>, until either the items are exhausted or the C<body>
invokes its C<$klast> continuation, then invoke C<$k>.

 $body->( $item, $knext, $klast )
    $knext->()
    $klast->()

 $k->()

=cut

sub kforeach
{
   my ( $items, $body, $k ) = @_;

   ref $items eq "ARRAY" or croak 'Expected $items as ARRAY ref';
   ref $body eq "CODE" or croak 'Expected $body as CODE ref';

   my $idx = 0;

   kwhile(
      sub {
         my ( $knext, $klast ) = @_;
         goto &$klast unless $idx < scalar @$items;
         @_ =(
            $items->[$idx++],
            $knext,
            $klast
         );
         goto &$body;
      },
      $k,
   );
}

=head2 kmap( \@items, \&body, $k )

CPS version of perl's C<map> statement. Calls the C<body> code once for each
element in C<@items>, capturing the list of values the body passes into its
continuation. When the items are exhausted, C<$k> is invoked and passed a list
of all the collected values.

 $body->( $item, $kret )
    $kret->( @items_out )

 $k->( @all_items_out )

=cut

sub kmap
{
   my ( $items, $body, $k ) = @_;

   ref $items eq "ARRAY" or croak 'Expected $items as ARRAY ref';
   ref $body eq "CODE" or croak 'Expected $body as CODE ref';

   my @ret;
   my $idx = 0;

   kwhile(
      sub {
         my ( $knext, $klast ) = @_;
         goto &$klast unless $idx < scalar @$items;
         @_ = (
            $items->[$idx++],
            sub { push @ret, @_; goto &$knext }
         );
         goto &$body;
      },
      sub { $k->( @ret ) },
   );
}

=head2 kgrep( \@items, \&body, $k )

CPS version of perl's C<grep> statement. Calls the C<body> code once for each
element in C<@items>, capturing those elements where the body's continuation
was invoked with a true value. When the items are exhausted, C<$k> is invoked
and passed a list of the subset of C<@items> which were selected.

 $body->( $item, $kret )
    $kret->( $select )

 $k->( @chosen_items )

=cut

sub kgrep
{
   my ( $items, $body, $k ) = @_;

   ref $items eq "ARRAY" or croak 'Expected $items as ARRAY ref';
   ref $body eq "CODE" or croak 'Expected $body as CODE ref';

   my @ret;
   my $idx = 0;

   kwhile(
      sub {
         my ( $knext, $klast ) = @_;
         goto &$klast unless $idx < scalar @$items;
         my $item = $items->[$idx++];
         @_ = (
            $item,
            sub { push @ret, $item if $_[0]; goto &$knext }
         );
         goto &$body;
      },
      sub { $k->( @ret ) },
   );
}

=head2 kfoldl( \@items, \&body, $k )

CPS version of C<List::Util::reduce>, which collapses (or "folds") a list of
values down to a single scalar, by successively accumulating values together.

If C<@items> is empty, invokes C<$k> immediately, passing in C<undef>.

If C<@items> contains a single value, invokes C<$k> immediately, passing in
just that single value.

Otherwise, initialises an accumulator variable with the first value in
C<@items>, then for each additional item, invokes the C<body> passing in the
accumulator and the next item, storing back into the accumulator the value
that C<body> passed to its continuation. When the C<@items> are exhausted, it
invokes C<$k>, passing in the final value of the accumulator.

 $body->( $acc, $item, $kret )
    $kret->( $new_acc )

 $k->( $final_acc )

Technically, this is not a true Scheme/Haskell-style C<foldl>, as it does not
take an initial value. (It is what Haskell calls C<foldl1>.) However, if such
an initial value is required, this can be provided by

 kfoldl( [ $initial, @items ], \&body, $k )

=cut

sub kfoldl
{
   my ( $items, $body, $k ) = @_;

   ref $items eq "ARRAY" or croak 'Expected $items as ARRAY ref';
   ref $body eq "CODE" or croak 'Expected $body as CODE ref';

   $k->( undef ),       return if @$items == 0;
   $k->( $items->[0] ), return if @$items == 1;

   my $idx = 0;
   my $acc = $items->[$idx++];

   kwhile(
      sub {
         my ( $knext, $klast ) = @_;
         goto &$klast unless $idx < scalar @$items;
         @_ = (
            $acc,
            $items->[$idx++],
            sub { $acc = shift; goto &$knext }
         );
         goto &$body;
      },
      sub { $k->( $acc ) },
   );
}

=head2 kfoldr( \@items, \&body, $k )

A right-associative version of C<kfoldl()>. Where C<kfoldl()> starts with the
first two elements in C<@items> and works forward, C<kfoldr()> starts with the
last two and works backward.

 $body->( $item, $acc, $kret )
    $kret->( $new_acc )

 $k->( $final_acc )

As before, an initial value can be provided by modifying the C<@items> array,
though note it has to be last this time:

 kfoldr( [ @items, $initial ], \&body, $k )

=cut

sub kfoldr
{
   my ( $items, $body, $k ) = @_;

   ref $items eq "ARRAY" or croak 'Expected $items as ARRAY ref';
   ref $body eq "CODE" or croak 'Expected $body as CODE ref';

   $k->( undef ),       return if @$items == 0;
   $k->( $items->[0] ), return if @$items == 1;

   my $idx = scalar(@$items) - 1;
   my $acc = $items->[$idx--];

   kwhile(
      sub {
         my ( $knext, $klast ) = @_;
         goto &$klast if $idx < 0;
         @_ = (
            $items->[$idx--],
            $acc,
            sub { $acc = shift; goto &$knext }
         );
         goto &$body;
      },
      sub { $k->( $acc ) },
   );
}

=head2 kgenerate( $seed, \&body, $k )

An inverse operation to C<kfoldl()>; turns a single scalar into a list of
items. Repeatedly calls the C<body> code, capturing the values it generates,
until it indicates the end of the loop, then invoke C<$k> with the collected
values.

 $body->( $seed, $kmore, $kdone )
    $kmore->( $new_seed, @items )
    $kdone->( @items )

 $k->( @all_items )

With each iteration, the C<body> is invoked and passed the current C<$seed>
value and two continuations, C<$kmore> and C<$kdone>. If C<$kmore> is invoked,
the passed items, if any, are appended to the eventual result list. The
C<body> is then re-invoked with the new C<$seed> value. If C<$klast> is
invoked, the passed items, if any, are appended to the return list, then the
entire list is passed to C<$k>.

=cut

sub kgenerate
{
   my ( $seed, $body, $k ) = @_;

   ref $body eq "CODE" or croak 'Expected $body as CODE ref';

   my @ret;

   kwhile(
      sub {
         my ( $knext, $klast ) = @_;
         @_ = (
            $seed,
            sub { $seed = shift; push @ret, @_; goto &$knext },
            sub { push @ret, @_; goto &$klast },
         );
         goto &$body;
      },
      sub { $k->( @ret ) },
   );
}

=head1 CPS UTILITIES

These function names do not begin with C<k> because they are not themselves
CPS primatives, but may be useful in CPS-oriented code.

=cut

=head2 $kfunc = liftk { BLOCK }

=head2 $kfunc = liftk( \&func )

Returns a new CODE reference to a CPS-wrapped version of the code block or 
passed CODE reference. When C<$kfunc> is invoked, the function C<&func> is
called in list context, being passed all the arguments given to C<$kfunc>
apart from the last, expected to be its continuation. When C<&func> returns,
the result is passed into the continuation.

 $kfunc->( @func_args, $k )
    $k->( @func_ret )

The following are equivalent

 print func( 1, 2, 3 );

 my $kfunc = liftk( \&func );
 $kfunc->( 1, 2, 3, sub { print @_ } );

Note that the returned wrapper function only has one continuation slot in its
arguments. It therefore cannot be used as the body for C<kwhile()>,
C<kforeach()> or C<kgenerate()>, because these pass two continuations. There
does not exist a "natural" way to lift a normal call/return function into a
CPS function which requires more than one continuation, because there is no
way to distinguish the different named returns.

=cut

sub liftk(&)
{
   my ( $code ) = @_;

   return sub {
      my $k = pop;
      @_ = $code->( @_ );
      goto &$k;
   };
}

# Keep perl happy; keep Britain tidy
1;

__END__

=head1 EXAMPLES

The following aren't necessarily examples of code which would be found in real
programs, but instead, demonstrations of how to use the above functions as
ways of controlling program flow.

Without dragging in large amount of detail on an asynchronous or event-driven
framework, it is difficult to give a useful example of behaviour that CPS
allows that couldn't be done just as easily without. Nevertheless, I hope the
following examples will be useful to demonstrate use of the above functions,
in a way which hints at their use in a real program.

=head2 Implementing C<join()> using C<kfoldl()>

 use CPS qw( kfoldl );

 my @words = qw( My message here );

 kfoldl(
    \@words,
    sub {
       my ( $left, $right, $k ) = @_;

       $k->( "$left $right" );
    },
    sub {
       my ( $str ) = @_;

       print "Joined up words: $str\n";
    }
 );

=head2 Implementing C<split()> using C<kgenerate()>

The following program illustrates the way that C<kgenerate()> can split a
string, in a reverse way to the way C<kfoldl()> can join it.

 use CPS qw( kgenerate );

 my $str = "My message here";

 kgenerate(
    $str,
    sub {
       my ( $s, $kmore, $kdone ) = @_;

       if( $s =~ s/^(.*?) // ) {
          return $kmore->( $s, $1 );
       }
       else {
          return $kdone->( $s );
       }
    },
    sub {
       my @words = @_;
       print "Words in message:\n";
       print "$_\n" for @words;
    }
 );

=head2 Generating Prime Numbers

While the design of C<kgenerate()> is symmetric to C<kfoldl()>, the seed value
doesn't have to be successively broken apart into pieces. Another valid use
for it may be storing intermediate values in computation, such as in this
example, storing a list of known primes, to help generate the next one:

 use CPS qw( kgenerate );
 
 kgenerate(
    [ 2, 3 ],
    sub {
       my ( $vals, $kmore, $kdone ) = @_;
 
       return $kdone->() if @$vals >= 50;
 
       PRIME: for( my $n = $vals->[-1] + 2; ; $n += 2 ) {
          $n % $_ == 0 and next PRIME for @$vals;
 
          push @$vals, $n;
          return $kmore->( $vals, $n );
       }
    },
    sub {
       my @primes = ( 2, 3, @_ );
       print "Primes are @primes\n";
    }
 );

=head2 Forward-reading Program Flow

One side benefit of the CPS control-flow methods which is unassociated with
asynchronous operation, is that the flow of data reads in a more natural
left-to-right direction, instead of the right-to-left flow in functional
style. Compare

 sub square { $_ * $_ }
 sub add { $a + $b }

 print reduce( \&add, map( square, primes(10) ) );

(because C<map> is a language builtin but C<reduce> is a function with C<(&)>
prototype, it has a different way to pass in the named functions)

with

 my $ksquare = liftk { $_[0] * $_[0] };
 my $kadd = liftk { $_[0] + $_[1] };

 kprimes 10, sub {
    kmap \@_, $ksquare, sub {
       kfoldl \@_, $kadd, sub {
          print $_[0];
       }
    }
 };

This translates roughly to a functional vs imperative way to describe the
problem:

 Print the sum of the squares of the first 10 primes.

 Take the first 10 primes. Square them. Sum them. Print.

Admittedly the closure creation somewhat clouds the point in this small
example, but in a larger example, the real problem-solving logic would be
larger, and stand out more clearly against the background boilerplate.

=head1 SEE ALSO

=over 4

=item *

L<Continuation-passing style |http://en.wikipedia.org/wiki/Continuation-passing_style>
on wikipedia

=item *

L<Coro> - co-routines in Perl

=back

=head1 AUTHOR

Paul Evans E<lt>leonerd@leonerd.org.ukE<gt>
