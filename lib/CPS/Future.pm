#  You may distribute under the terms of either the GNU General Public License
#  or the Artistic License (the same terms as Perl itself)
#
#  (C) Paul Evans, 2011-2012 -- leonerd@leonerd.org.uk

package CPS::Future;

use strict;
use warnings;

our $VERSION = '0.15';

use Carp;
use Scalar::Util qw( weaken );

=head1 NAME

C<CPS::Future> - represent an operation awaiting completion

=head1 SYNOPSIS

 my $future = CPS::Future->new;
 $future->on_ready( sub {
    say "The operation is complete";
 } );

 kperform_some_operation( sub {
    $future->done( @_ );
 } );

=head1 DESCRIPTION

An C<CPS::Future> object represents an operation that is currently in
progress, or has recently completed. It can be used in a variety of ways to
manage the flow of control, and data, through an asynchronous program.

Some futures represent a single operation (returned by the C<new>
constructor), and are explicitly marked as ready by calling the C<done>
method. Others represent a tree of sub-tasks (returned by the C<wait_all>
or C<needs_all> constructors), and are implicitly marked as ready when all
of their component futures are ready.

It is intended that library functions that perform asynchonous operations
would use C<CPS::Future> objects to represent outstanding operations, and
allow their calling programs to control or wait for these operations to
complete. The implementation and the user of such an interface would typically
make use of different methods on the class. The methods below are documented
in two sections; those of interest to each side of the interface.

=cut

=head1 CONSTRUCTORS

=cut

=head2 $future = CPS::Future->new

Returns a new C<CPS::Future> instance to represent a leaf future. It will be
marked as ready by any of the C<done>, C<fail>, or C<cancel> methods.

This constructor would primarily be used by implementations of asynchronous
interfaces.

=cut

sub new
{
   my $class = shift;
   return bless {
      ready     => 0,
      callbacks => [],
   }, $class;
}

sub _new_with_subs
{
   my $self = shift->new;
   my ( $subs ) = @_;

   eval { $_->isa( __PACKAGE__ ) } or croak "Expected a ".__PACKAGE__.", got $_" for @$subs;

   $self->{result} = $subs;

   $self->on_cancel( sub {
      foreach my $sub ( @$subs ) {
         $sub->cancel if !$sub->is_ready;
      }
   } );

   return $self;
}

=head2 $future = CPS::Future->wait_all( @subfutures )

Returns a new C<CPS::Future> instance that will indicate it is ready once all
of the sub future objects given to it indicate that they are ready.

This constructor would primarily be used by users of asynchronous interfaces.

=cut

sub wait_all
{
   my $class = shift;
   my @subs = @_;

   my $self = $class->_new_with_subs( \@subs );

   weaken( my $weakself = $self );
   my $sub_on_ready = sub {
      foreach my $sub ( @subs ) {
         $sub->is_ready or return;
      }
      $weakself and $weakself->_mark_ready;
   };

   foreach my $sub ( @subs ) {
      $sub->on_ready( $sub_on_ready );
   }

   return $self;
}

=head2 $future = CPS::Future->needs_all( @subfutures )

Returns a new C<CPS::Future> instance that will indicate it is ready once all
of the sub future objects given to it indicate that they have completed
successfully, or when any of them indicates that they have failed. If any sub
future fails, then this will fail immediately, and the remaining subs not yet
ready will be cancelled.

This constructor would primarily be used by users of asynchronous interfaces.

=cut

sub needs_all
{
   my $class = shift;
   my @subs = @_;

   my $self = $class->_new_with_subs( \@subs );

   weaken( my $weakself = $self );
   my $sub_on_ready = sub {
      return unless $weakself;

      if( my @failure = $_[0]->failure ) {
         $weakself->{failure} = \@failure;
         foreach my $sub ( @subs ) {
            $sub->cancel if !$sub->is_ready;
         }
         $weakself->_mark_ready;
      }
      else {
         foreach my $sub ( @subs ) {
            $sub->is_ready or return;
         }
         $weakself->_mark_ready;
      }
   };

   foreach my $sub ( @subs ) {
      $sub->on_ready( $sub_on_ready );
   }

   return $self;
}

=head2 $future = $f1->and_then( \&code )

Returns a new C<CPS::Future> instance that allows a sequence of dependent
operations to be performed. Once C<$f1> indicates a successful completion, the
code reference will be invoked and is passed one argument, being C<$f1>. It
should return a new future, C<$f2>. Once C<$f2> indicates completion the
combined future C<$future> will then be marked as complete. The result of
calling C<get> on the combined future will return whatever was passed to the
C<done> method of C<$f2>.

 $f2 = $code->( $f1 )

If C<$f1> fails then C<$future> will indicate this failure immediately and the
block of code will not be invoked.

If C<$future> is cancelled before C<$f1> completes, then C<$f1> will be
cancelled. If it is cancelled after completion then C<$f2> is cancelled
instead.

=cut

sub and_then
{
   my $f1 = shift;
   my ( $code ) = @_;

   my $fseq = CPS::Future->new;

   my $f2;

   $f1->on_ready( sub {
      my $self = shift;

      if( $self->is_cancelled ) {
         return;
      }

      if( $self->failure ) {
         $fseq->fail( $self->failure );
         return;
      }

      $f2 = $code->( $self );

      $f2->on_ready( sub {
         my $f2 = shift;
         if( $f2->is_cancelled ) {
            return;
         }
         elsif( $f2->failure ) {
            $fseq->fail( $f2->failure );
         }
         else {
            $fseq->done( $f2->get );
         }
      } );
   } );

   $fseq->on_cancel( sub {
      ( $f2 || $f1 )->cancel
   } );

   return $fseq;
}

=head2 $future = $f1->transform( %args )

Returns a new C<CPS::Future> instance that wraps the one given as C<$f1>. With
no arguments this will be a trivial wrapper; C<$future> will complete or fail
when C<$f1> does, and C<$f1> will be cancelled when C<$future> is.

By passing the following named argmuents, the returned C<$future> can be made
to behave differently to C<$f1>:

=over 8

=item done => CODE

Provides a function to use to modify the result of a successful completion.
When C<$f1> completes successfully, the result of its C<get> method is passed
into this function, and whatever it returns is passed to the C<done> method of
C<$future>

=item fail => CODE

Provides a function to use to modify the result of a failure. When C<$f1>
fails, the result of its C<failure> method is passed into this function, and
whatever it returns is passed to the C<fail> method of C<$future>.

=back

=cut

sub transform
{
   my $self = shift;
   my %args = @_;

   my $xfrm_done = $args{done};
   my $xfrm_fail = $args{fail};

   my $ret = CPS::Future->new;

   $self->on_ready(
      sub {
         my $self = shift;
         if( $self->is_cancelled ) { }
         elsif( $self->failure ) {
            $ret->fail( $xfrm_fail ? $xfrm_fail->( $self->failure ) : $self->failure )
         }
         else {
            $ret->done( $xfrm_done ? $xfrm_done->( $self->get ) : $self->get );
         }
      }
   );

   $ret->on_cancel( sub { $self->cancel } );

   return $ret;
}

sub _mark_ready
{
   my $self = shift;
   $self->{ready} = 1;

   my $failed = defined $self->failure;
   my $done   = !$failed && !$self->is_cancelled;

   foreach my $cb ( @{ $self->{callbacks} } ) {
      $cb->[1]->( $self )          if $cb->[0] eq "ready";
      $cb->[1]->( $self->get )     if $cb->[0] eq "done"   and $done;
      $cb->[1]->( $self->failure ) if $cb->[0] eq "failed" and $failed;
   }

   delete $self->{callbacks}; # To drop references
}

=head1 IMPLEMENTATION METHODS

These methods would primarily be used by implementations of asynchronous
interfaces.

=cut

=head2 $future->done( @result )

Marks that the leaf future is now ready, and provides a list of values as a
result. (The empty list is allowed, and still indicates the future as ready).
Cannot be called on a non-leaf future.

Returns the C<$future>.

=cut

sub done
{
   my $self = shift;

   $self->is_ready and croak "$self is already complete and cannot be ->done twice";
   $self->{result} and croak "$self is not a leaf Future, cannot be ->done";
   $self->{result} = [ @_ ];
   $self->_mark_ready;

   return $self;
}

=head2 $future->fail( $exception, @details )

Marks that the leaf future has failed, and provides an exception value. This
exception will be thrown by the C<get> method if called. If the exception is a
non-reference that does not end in a linefeed, its value will be extended by
the file and line number of the caller, similar to the logic that C<die> uses.

The exception must evaluate as a true value; false exceptions are not allowed.
Further details may be provided that will be returned by the C<failure> method
in list context. These details will not be part of the exception string raised
by C<get>.

Returns the C<$future>.

=cut

sub fail
{
   my $self = shift;
   my ( $exception, @details ) = @_;

   $self->is_ready and croak "$self is already complete and cannot be ->fail'ed";
   $self->{result} and croak "$self is not a leaf Future, cannot be ->fail'ed";
   $_[0] or croak "$self ->fail requires an exception that is true";
   if( !ref $exception and $exception !~ m/\n$/ ) {
      $exception .= sprintf " at %s line %d\n", (caller)[1,2];
   }
   $self->{failure} = [ $exception, @details ];
   $self->_mark_ready;

   return $self;
}

=head2 $future->on_cancel( $code )

If the future is not yet ready, adds a callback to be invoked if the future is
cancelled by the C<cancel> method. If the future is already ready, throws an
exception.

If the future is cancelled, the callbacks will be invoked in the reverse order
to that in which they were registered.

 $on_cancel->( $future )

=cut

sub on_cancel
{
   my $self = shift;
   $self->is_ready and croak "$self is already complete and cannot register more ->on_cancel handlers";
   push @{ $self->{on_cancel} }, @_;
}

=head2 $cancelled = $future->is_cancelled

Returns true if the future has been cancelled by C<cancel>.

=cut

sub is_cancelled
{
   my $self = shift;
   return $self->{cancelled};
}

=head1 USER METHODS

These methods would primarily be used by users of asynchronous interfaces, on
objects returned by such an interface.

=cut

=head2 $ready = $future->is_ready

Returns true on a leaf future if a result has been provided to the C<done>
method, failed using the C<fail> method, or cancelled using the C<cancel>
method.

Returns true on a C<wait_all> future if all the sub-tasks are ready.

Returns true on a C<needs_all> future if all the sub-tasks have completed
successfully or if any of them have failed.

=cut

sub is_ready
{
   my $self = shift;
   return $self->{ready};
}

=head2 $future->on_ready( $code )

If the future is not yet ready, adds a callback to be invoked when the future
is ready. If the future is already ready, invokes it immediately.

In either case, the callback will be passed the future object itself. The
invoked code can then obtain the list of results by calling the C<get> method.

 $on_ready->( $future )

Returns the C<$future>.

=cut

sub on_ready
{
   my $self = shift;
   my ( $code ) = @_;

   if( $self->is_ready ) {
      $code->( $self );
   }
   else {
      push @{ $self->{callbacks} }, [ ready => $code ];
   }

   return $self;
}

=head2 @result = $future->get

If the future is ready, returns the list of results that had earlier been
given to the C<done> method. If not, will raise an exception.

If called on a C<wait_all> or C<needs_all> future, it will return a list of
the futures it was waiting on, in the order they were passed to the
constructor.

=cut

sub get
{
   my $self = shift;
   $self->is_ready or croak "$self is not yet complete";
   die $self->{failure}->[0] if $self->{failure};
   $self->is_cancelled and croak "$self was cancelled";
   return @{ $self->{result} };
}

=head2 $future->on_done( $code )

If the future is not yet ready, adds a callback to be invoked when the future
is ready, if it completes successfully. If the future completed successfully,
invokes it immediately. If it failed or was cancelled, it is not invoked at
all.

The callback will be passed the result passed to the C<done> method.

 $on_done->( @result )

Returns the C<$future>.

=cut

sub on_done
{
   my $self = shift;
   my ( $code ) = @_;

   if( $self->is_ready and !$self->failure and !$self->is_cancelled ) {
      $code->( $self->get );
   }
   else {
      push @{ $self->{callbacks} }, [ done => $code ];
   }

   return $self;
}

=head2 $exception = $future->failure

=head2 $exception, @details = $future->failure

Returns the exception passed to the C<fail> method, C<undef> if the future
completed successfully via the C<done> method, or raises an exception if
called on a future that is not yet ready.

If called in list context, will additionally yield a list of the details
provided to the C<fail> method.

Because the exception value must be true, this can be used in a simple C<if>
statement:

 if( my $exception = $future->failure ) {
    ...
 }
 else {
    my @result = $future->get;
    ...
 }

=cut

sub failure
{
   my $self = shift;
   $self->is_ready or croak "$self is not yet complete";
   return unless $self->{failure};
   return $self->{failure}->[0] if !wantarray;
   return @{ $self->{failure} };
}

=head2 $future->on_fail( $code )

If the future is not yet ready, adds a callback to be invoked when the future
is ready, if it fails. If the future has already failed, invokes it
immediately. If it completed successfully or was cancelled, it is not invoked
at all.

The callback will be passed the exception and details passed to the C<fail>
method.

 $on_fail->( $exception, @details )

Returns the C<$future>.

=cut

sub on_fail
{
   my $self = shift;
   my ( $code ) = @_;

   if( $self->is_ready and $self->failure ) {
      $code->( $self->failure );
   }
   else {
      push @{ $self->{callbacks} }, [ failed => $code ];
   }

   return $self;
}

=head2 $future->cancel

Requests that the future be cancelled, immediately marking it as ready. This
will invoke all of the code blocks registered by C<on_cancel>, in the reverse
order. When called on a non-leaf future, all its sub-tasks are also cancelled.

=cut

sub cancel
{
   my $self = shift;

   $self->{cancelled}++;
   foreach my $cb ( reverse @{ $self->{on_cancel} || [] } ) {
      $cb->( $self );
   }
   $self->_mark_ready;
}

=head1 EXAMPLES

The following examples all demonstrate possible uses of a C<CPS::Future>
object to provide a fictional asynchronous API function called simply
C<koperation>.

=head2 Providing Results

By returning a new C<CPS::Future> object each time the asynchronous function
is called, it provides a placeholder for its eventual result, and a way to
indicate when it is complete.

 sub koperation
 {
    my %args = @_;

    my $future = CPS::Future->new;

    kdo_something(
       foo => $args{foo},
       on_done => sub { $future->done( @_ ); },
    );
 }

The caller may then use this future to wait for a result using the C<on_ready>
method, and obtain the result using C<get>.

 my $f = koperation( foo => "something" );

 $f->on_ready( sub {
    my $f = shift;
    say "The operation returned: ", $f->get;
 } );

=head2 Indicating Success or Failure

Because the stored exception value of a failued C<CPS::Future> may not be
false, the C<failure> method can be used in a conditional statement to detect
success or failure.

 my $f = koperation( foo => "something" );

 $f->on_ready( sub {
    my $f = shift;
    if( not my $e = $f->failure ) {
       say "The operation succeeded with: ", $f->get;
    }
    else {
       say "The operation failed with: ", $e;
    }
 } );

By using C<not> in the condition, the order of the C<if> blocks can be
arranged to put the successful case first, similar to a C<try>/C<catch> block.

Because the C<get> method re-raises the passed exception if the future failed,
it can be used to control a C<try>/C<catch> block directly. (This is sometimes
called I<Exception Hoisting>).

 use Try::Tiny;

 $f->on_ready( sub {
    my $f = shift;
    try {
       say "The operation succeeded with: ", $f->get;
    }
    catch {
       say "The operation failed with: ", $_;
    };
 } );

=head2 Merging Control Flow

A C<wait_all> future may be used to resynchronise control flow, while waiting
for multiple concurrent operations to finish.

 my $f1 = koperation( foo => "something" );
 my $f2 = koperation( bar => "something else" );

 my $f = CPS::Future->wait_all( $f1, $f2 );

 $f->on_ready( sub {
    say "Operations are ready:";
    say "  foo: ", $f1->get;
    say "  bar: ", $f2->get;
 } );

This provides an ability somewhat similar to C<CPS::kpar()> or
L<Async::MergePoint>.

=cut

=head1 TODO

Lots of things still need adding. API or semantics is somewhat unclear in
places.

=over 4

=item *

C<< CPS::Future->needs_first >>, which succeeds on the first success of
dependent futures and cancels the outstanding ones, only fails if all the
dependents do.

=item *

Some way to do deferred futures that don't even start their operation until
invoked somehow. Ability to chain these together in a sequence, like
C<CPS::kseq()>.

=back

=head1 AUTHOR

Paul Evans <leonerd@leonerd.org.uk>

=cut

0x55AA;
