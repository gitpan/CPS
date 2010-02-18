#  You may distribute under the terms of either the GNU General Public License
#  or the Artistic License (the same terms as Perl itself)
#
#  (C) Paul Evans, 2008-2010 -- leonerd@leonerd.org.uk

package CPS;

use strict;
use warnings;

our $VERSION = '0.08';

use Carp;

use Scalar::Util qw( weaken );

use Exporter 'import';

our @CPS_PRIMS = qw(
   kwhile
   kforeach
   kmap
   kgrep
   kfoldl kfoldr
   kgenerate
   kdescendd kdescendb

   kpar
);

our @EXPORT_OK = (
   @CPS_PRIMS,
   map( "g$_", @CPS_PRIMS ),

qw(
   liftk
   dropk
),
);

use CPS::Governor::Simple;

# Don't hard-depend on Sub::Name since it's only a niceness for stack traces
BEGIN {
   if( eval { require Sub::Name } ) {
      *subname = \&Sub::Name::subname;
   }
   else {
      # Ignore the name, return the CODEref
      *subname = sub { return $_[1] };
   }
}

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

sub gkwhile
{
   my ( $gov, $body, $k ) = @_;

   ref $body eq "CODE" or croak 'Expected $body as CODE ref';
   ref $k  eq "CODE" or croak 'Expected $k as CODE ref';

   my $sync;
   my $do_again = 0;

   # We can't just call this as a method because we need to tailcall it
   # Instead, keep a reference to the actual method so we can goto &$again
   my $again = $gov->can('again') or croak "Governor cannot ->again";

   my $iter; $iter = subname gkwhile => sub {
      my $knext = $iter;

      $sync = 1;
      $body->(
         sub {
            if( $sync ) { $do_again=1 }
            else        { @_ = ( $gov, $knext ); goto &$again; }
         },
         sub { undef $iter; goto &$k },
      );
      $sync = 0;

      if( $do_again ) {
         $do_again = 0;
         @_ = ( $gov, $knext );
         goto &$again;
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

sub gkforeach
{
   my ( $gov, $items, $body, $k ) = @_;

   ref $items eq "ARRAY" or croak 'Expected $items as ARRAY ref';
   ref $body eq "CODE" or croak 'Expected $body as CODE ref';

   my $idx = 0;

   gkwhile( $gov,
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

sub gkmap
{
   my ( $gov, $items, $body, $k ) = @_;

   ref $items eq "ARRAY" or croak 'Expected $items as ARRAY ref';
   ref $body eq "CODE" or croak 'Expected $body as CODE ref';

   my @ret;
   my $idx = 0;

   gkwhile( $gov,
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

sub gkgrep
{
   my ( $gov, $items, $body, $k ) = @_;

   ref $items eq "ARRAY" or croak 'Expected $items as ARRAY ref';
   ref $body eq "CODE" or croak 'Expected $body as CODE ref';

   my @ret;
   my $idx = 0;

   gkwhile( $gov,
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

sub gkfoldl
{
   my ( $gov, $items, $body, $k ) = @_;

   ref $items eq "ARRAY" or croak 'Expected $items as ARRAY ref';
   ref $body eq "CODE" or croak 'Expected $body as CODE ref';

   $k->( undef ),       return if @$items == 0;
   $k->( $items->[0] ), return if @$items == 1;

   my $idx = 0;
   my $acc = $items->[$idx++];

   gkwhile( $gov,
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

sub gkfoldr
{
   my ( $gov, $items, $body, $k ) = @_;

   ref $items eq "ARRAY" or croak 'Expected $items as ARRAY ref';
   ref $body eq "CODE" or croak 'Expected $body as CODE ref';

   $k->( undef ),       return if @$items == 0;
   $k->( $items->[0] ), return if @$items == 1;

   my $idx = scalar(@$items) - 1;
   my $acc = $items->[$idx--];

   gkwhile( $gov,
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

sub gkgenerate
{
   my ( $gov, $seed, $body, $k ) = @_;

   ref $body eq "CODE" or croak 'Expected $body as CODE ref';

   my @ret;

   gkwhile( $gov,
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

=head2 kdescendd( $root, \&body, $k )

CPS version of recursive descent on a tree-like structure, defined by a
function, C<body>, which when given a node in the tree, yields a list of
child nodes.

 $body->( $node, $kmore )
    $kmore->( @child_nodes )

 $k->()

The first value to be passed into C<body> is C<$root>. 

At each iteration, a node is given to the C<body> function, and it is expected
to pass a list of child nodes into its C<$kmore> continuation. These will then
be iterated over, in the order given. The tree-like structure is visited 
depth-first, descending fully into one subtree of a node before moving on to
the next.

This function does not provide a way for the body to accumulate a resultant
data structure to pass into its own continuation. The body is executed simply
for its side-effects and its continuation is invoked with no arguments. A
variable of some sort should be shared between the body and the continuation
if this is required.

=cut

sub gkdescendd
{
   my ( $gov, $root, $body, $k ) = @_;

   ref $body eq "CODE" or croak 'Expected $body as CODE ref';

   my @stack = ( $root );

   gkwhile( $gov,
      sub {
         my ( $knext, $klast ) = @_;
         @_ = (
            shift @stack,
            sub {
               unshift @stack, @_;

               goto &$knext if @stack;
               goto &$klast;
            },
         );
         goto &$body;
      },
      $k,
   );
}

=head2 kdescendb( $root, \&body, $k )

A breadth-first variation of C<kdescendd>. This function visits each child
node of the parent, before iterating over all of these nodes's children,
recursively until the bottom of the tree.

=cut

sub gkdescendb
{
   my ( $gov, $root, $body, $k ) = @_;

   ref $body eq "CODE" or croak 'Expected $body as CODE ref';

   my @queue = ( $root );

   gkwhile( $gov,
      sub {
         my ( $knext, $klast ) = @_;
         @_ = (
            shift @queue,
            sub {
               push @queue, @_;

               goto &$knext if @queue;
               goto &$klast;
            },
         );
         goto &$body;
      },
      $k,
   );
}

=head2 kpar( @bodies, $k )

This CPS function takes a list of function bodies and calls them all. Each is
given a continuation to invoke. Once every body has invoked its continuation,
the main continuation C<$k> is invoked.

 $body->( $kdone )
   $kdone->()

 $k->()

This allows running multiple operations in parallel, and waiting for them all
to complete before continuing. It provides in a CPS form functionallity
similar to that provided in a more object-oriented fashion by modules such as
L<Async::MergePoint> or L<Event::Join>.

=cut

sub gkpar
{
   my ( $gov, @bodies ) = @_;
   my $k = pop @bodies;

   $gov->can('enter') or croak "Governor cannot ->enter";

   my $sync = 1;
   my @outstanding;
   my $kdone = sub {
      return if $sync;
      $_ and return for @outstanding;
      goto &$k;
   };

   foreach my $idx ( 0 .. $#bodies ) {
      $outstanding[$idx]++;
      $gov->enter( $bodies[$idx], sub {
         $outstanding[$idx]--;
         goto &$kdone;
      } );
   }

   $sync = 0;
   goto &$kdone;
}

=head1 GOVERNORS

All of the above functions are implemented using a loop which repeatedly calls
the body function until some terminating condition. By controlling the way
this loop re-invokes itself, a program can control the behaviour of the
functions.

For every one of the above functions, there also exists a variant which takes
a L<CPS::Governor> object as its first argument. These functions use the
governor object to control their iteration.

 kwhile( \&body, $k )
 gkwhile( $gov, \&body, $k )

 kforeach( \@items, \&body, $k )
 gkforeach( $gov, \@items, \&body, $k )

 etc...

In this way, other governor objects can be constructed which have different
running properties; such as interleaving iterations of their loop with other
IO activity in an event-driven framework, or giving rate-limitation control on
the speed of iteration of the loop.

=cut

# The above is a lie. The basic functions provided are actually the gk*
# versions; we wrap these to make the normal k* functions by passing a simple
# governor.
{
   my $default_gov = CPS::Governor::Simple->new;

   no strict 'refs';

   foreach my $prim ( @CPS_PRIMS  ) {
      my $func = \&{"g$prim"};
      *{$prim} = subname $prim => sub {
         unshift @_, $default_gov;
         goto &$func;
      };
   }
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

=head2 $func = dropk { BLOCK } $kfunc

=head2 $func = dropk $waitfunc, $kfunc

Returns a new CODE reference to a plain call/return version of the passed
CPS-style CODE reference. When the returned ("dropped") function is called,
it invokes the passed CPS function, then waits for it to invoke its
continuation. When it does, the list that was passed to the continuation is
returned by the dropped function. If called in scalar context, only the first
value in the list is returned.

 $kfunc->( @func_args, $k )
    $k->( @func_ret )

 $waitfunc->()

 @func_ret = $func->( @func_args )

Given the following trivial CPS function:

 $kadd = sub { $_[2]->( $_[0] + $_[1] ) };

The following are equivalent

 $kadd->( 10, 20, sub { print "The total is $_[0]\n" } );

 $add = dropk { } $kadd;
 print "The total is ".$add->( 10, 20 )."\n";

In the general case the CPS function hasn't yet invoked its continuation by
the time it returns (such as would be the case when using any sort of
asynchronisation or event-driven framework). For C<dropk> to actually work in
this situation, it requires a way to run the event framework, to cause it to
process events until the continuation has been invoked.

This is provided by the block, or the first passed CODE reference. When the
returned function is invoked, it repeatedly calls the block or wait function,
until the CPS function has invoked its continuation.

=cut

sub dropk(&$)
{
   my ( $waitfunc, $kfunc ) = @_;

   return sub {
      my @result;
      my $done;

      $kfunc->( @_, sub { @result = @_; $done = 1 } );

      while( !$done ) {
         $waitfunc->();
      }

      return wantarray ? @result : $result[0];
   }
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

=head2 Passing Values Using C<kpar>

No facilities are provided to pass data between body and final continuations
of C<kpar>. Instead, normal lexical variable capture may be used here.

 my $bat;
 my $ball;

 kpar(
    sub {
       my ( $k ) = @_;
       get_bat( on_bat => sub { $bat = shift; goto &$k } );
    },
    sub {
       my ( $k ) = @_;
       serve_ball( on_ball => sub { $ball = shift; goto &$k } );
    },

    sub {
       $bat->hit( $ball );
    },
 );

=head1 BUGS

=over 4

=item *

C<kwhile> is implemented using a cyclic code reference; an anonymous
function whose pad contains a reference to itself. This reference is
stored weakly, using C<Scalar::Util::weaken>.

On perl C<5.8.0> and later, this is correctly destroyed if the body function
fails to invoke or store either of its continuations; the body stalls and
fails to execute again, and any references it uniquely held are cleaned up.

On earlier perls (i.e. C<5.6.2> or earlier) this does not happen. In order not
to leak references on early perls it is essential that the body of the
C<kwhile> loop, or other functions, always either invokes one of its passed
continuations, or stores one somewhere for eventual invocation.

=back

=head1 SEE ALSO

=over 4

=item *

L<http://en.wikipedia.org/wiki/Continuation-passing_style> on wikipedia

=item *

L<Coro> - co-routines in Perl

=back

=head1 AUTHOR

Paul Evans <leonerd@leonerd.org.uk>
