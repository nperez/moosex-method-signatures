use strict;
use warnings;

package MooseX::Method::Signatures;

use Moose;
use Devel::Declare ();
use B::Hooks::EndOfScope;
use Moose::Meta::Class;
use MooseX::Types::Moose qw/Str Bool CodeRef/;
use Text::Balanced qw/extract_quotelike/;
use MooseX::Method::Signatures::Meta::Method;
use Sub::Name;
use Carp;

use aliased 'Devel::Declare::Context::Simple', 'DDContext';

use namespace::autoclean;

our $VERSION = '0.16';

has package => (
    is       => 'ro',
    isa      => Str,
    required => 1,
);

has context => (
    is      => 'ro',
    isa     => DDContext,
    lazy    => 1,
    builder => '_build_context',
);

has initialized_context => (
    is      => 'ro',
    isa     => Bool,
    default => 0,
);

has custom_method_application => (
    is        => 'ro',
    isa       => 'CodeRef',
    predicate => 'has_custom_method_application'
);

sub _build_context {
    my ($self) = @_;
    return MethodInstaller->new(into => $self->package);
}

sub import {
    my ($class) = @_;
    my $caller = caller();
    $class->setup_for($caller);
}

sub setup_for {
    my ($class, $pkg) = @_;
    my $self = $class->new(package => $pkg);
    
    Devel::Declare->setup_for($pkg, {
        method => { const => sub { $self->parser(@_) } },
    });

    {
        no strict 'refs';
        *{ "${pkg}::method" } = sub {};
    }

    return;
}

sub strip_name {
    my $self = shift;
    my $ctx = $self->context;
    my $ret = $ctx->strip_name;
    return $ret if defined $ret;

    my $line = $ctx->get_linestr;
    my $offset = $ctx->offset;
    local $@;
    my ($str) = extract_quotelike(substr($line, $offset));
    return unless defined $str;

    return if ($@ && $@ =~ /^No quotelike operator found/);
    die $@ if $@;

    substr($line, $offset, length $str) = '';
    $ctx->set_linestr($line);

    return \$str;
}

sub strip_traits {
    my ($self) = @_;

    my $ctx = $self->context;
    my $linestr = $ctx->get_linestr;

    unless (substr($linestr, $ctx->offset, 2) eq 'is') {
        # No is means no traits, return an empty arrayref
        return [];
    }

    my @traits = ();
    while (substr($linestr, $ctx->offset, 2) eq 'is') {
        # Eat the 'is' so we can call strip_names_and_args
        substr($linestr, $ctx->offset, 2) = '';
        $ctx->set_linestr($linestr);
        push(@traits, @{ $ctx->strip_names_and_args });
        # Get the current linestr so that the loop can look for more 'is'
        $linestr = $ctx->get_linestr;
    }

    confess "expected traits after 'is', found nothing"
        unless scalar(@traits);

    return \@traits;
}

sub strip_return_type_constraint {
    my $self = shift;
    my $ctx = $self->context;
    my $returns = $ctx->strip_name;
    return unless defined $returns;
    confess "expected 'returns', found '${returns}'"
        unless $returns eq 'returns';
    return $ctx->strip_proto;
}

sub parser {
    my $self = shift;
    my $err;

    # Keep any previous compile errors from getting stepped on. But report
    # errors from inside MXMS nicely.
    {
        local $@;
        eval { $self->_parser(@_) };
        $err = $@;
    }

    die $err if $err;
}

sub _parser {
    my $self = shift;
    my $ctx = $self->context;
    $ctx->init(@_) unless $self->initialized_context;

    $ctx->skip_declarator;
    my $name   = $self->strip_name;
    my $proto  = $ctx->strip_proto;
    my $attrs  = $self->strip_attrs || '';
    my $traits = $self->strip_traits;
    my $ret_tc = $self->strip_return_type_constraint;

    my $compile_stash = $ctx->get_curstash_name;

    my %args = (
      signature => q{(} . ($proto || '') . q{)},

      # This might get reset later, but its where we search for exported
      # symbols at compile time
      package_name => $compile_stash,
    );
    $args{traits} = $traits if defined $traits && scalar(@{ $traits });
    $args{return_signature} = $ret_tc if defined $ret_tc;
    my $method = MooseX::Method::Signatures::Meta::Method->wrap(%args);
    
    my $after_block = ')';

    if (defined $name) {
        my $name_arg = q{, } . (ref $name ? ${$name} : qq{q[${name}]});
        $after_block = $name_arg . $after_block . q{;};
    }
    
    my $inject = $method->injectable_code;
    $inject = $self->scope_injector_call($after_block) . $inject;

    $ctx->inject_if_block($inject, "(sub ${attrs} ");

    my $create_meta_method = sub {
        my ($code, $pkg, $meth_name) = @_;
        subname $pkg . "::" .$meth_name, $code;
        $method->_set_actual_body($code);
        $method->_set_package_name($pkg);
        $method->_set_name($meth_name);
        return $method;
    };

    if (defined $name) {
        my $apply = $self->has_custom_method_application
            ? $self->custom_method_application
            : sub {
                my ($meta, $name, $method) = @_;
                $meta->add_method($name => $method);
            };

        $ctx->shadow(sub {
            my ($code, $name) = @_;

            my $pkg = $compile_stash;
            ($pkg, $name) = $name =~ /^(.*)::([^:]+)$/
                if $name =~ /::/;

            my $meth = $create_meta_method->($code, $pkg, $name);
            my $meta = Moose::Meta::Class->initialize($pkg);
            my $meta_meth;

            if (warnings::enabled("redefine") &&
                ($meta_meth = $meta->get_method($name)) &&
                $meta_meth->isa('MooseX::Method::Signatures::Meta::Method')) {
                warnings::warn("redefine", "Method $name redefined on package $pkg");
            }

            $meta->$apply($name, $meth);
            return;
        });
    }
    else {
        $ctx->shadow(sub {
            return $create_meta_method->(shift, $compile_stash, '__ANON__');
        });
    }
}

sub scope_injector_call {
    my ($self, $code) = @_;
    return qq[BEGIN { ${\ref $self}->inject_scope('${code}') }];
}

sub inject_scope {
    my ($class, $inject) = @_;
    on_scope_end {
        my $line = Devel::Declare::get_linestr();
        return unless defined $line;
        my $offset = Devel::Declare::get_linestr_offset();
        substr($line, $offset, 0) = $inject;
        Devel::Declare::set_linestr($line);
    };
}

__PACKAGE__->meta->make_immutable;

1;

__END__
=head1 NAME

MooseX::Method::Signatures - Method declarations with type constraints and no source filter

=head1 SYNOPSIS

    package Foo;

    use Moose;
    use MooseX::Method::Signatures;

    method morning (Str $name) {
        $self->say("Good morning ${name}!");
    }

    method hello (Str :$who, Int :$age where { $_ > 0 }) {
        $self->say("Hello ${who}, I am ${age} years old!");
    }

    method greet (Str $name, Bool :$excited = 0) {
        if ($excited) {
            $self->say("GREETINGS ${name}!");
        }
        else {
            $self->say("Hi ${name}!");
        }
    }

    $foo->morning('Resi');                          # This works.

    $foo->hello(who => 'world', age => 42);         # This too.

    $foo->greet('Resi', excited => 1);              # And this as well.

    $foo->hello(who => 'world', age => 'fortytwo'); # This doesn't.

    $foo->hello(who => 'world', age => -23);        # This neither.

    $foo->morning;                                  # Won't work.

    $foo->greet;                                    # Will fail.

=head1 DISCLAIMER

This is B<ALPHA SOFTWARE>. Use at your own risk. Features may change.

=head1 DESCRIPTION

Provides a proper method keyword, like "sub" but specifically for making methods
and validating their arguments against Moose type constraints.

=head1 SIGNATURE SYNTAX

The signature syntax is heavily based on Perl 6. However not the full Perl 6
signature syntax is supported yet and some of it never will be.

=head2 Type Constraints

    method foo (             $affe) # no type checking
    method bar (Animal       $affe) # $affe->isa('Animal')
    method baz (Animal|Human $affe) # $affe->isa('Animal') || $affe->isa('Human')

=head2 Positional vs. Named

    method foo ( $a,  $b,  $c) # positional
    method bar (:$a, :$b, :$c) # named
    method baz ( $a,  $b, :$c) # combined

=head2 Required vs. Optional

    method foo ($a , $b!, :$c!, :$d!) # required
    method bar ($a?, $b?, :$c , :$d?) # optional

=head2 Defaults

    method foo ($a = 42) # defaults to 42

=head2 Constraints

    method foo ($foo where { $_ % 2 == 0 }) # only even

=head2 Invocant

    method foo (        $moo) # invocant is called $self and is required
    method bar ($self:  $moo) # same, but explicit
    method baz ($class: $moo) # invocant is called $class

=head2 Labels

    method foo (:     $affe ) # called as $obj->foo(affe => $value)
    method bar (:apan($affe)) # called as $obj->foo(apan => $value)

=head2 Traits

    method foo (Affe $bar does trait)
    method foo (Affe $bar is trait)

The only currently supported trait is C<coerce>, which will attempt to coerce
the value provided if it doesn't satisfy the requirements of the type
constraint.

=head2 Placeholders

    method foo ($bar, $, $baz)

Sometimes you don't care about some params you're being called with. Just put
the bare sigil instead of a full variable name into the signature to avoid an
extra lexical variable to be created.

=head2 Complex Example

    method foo ( SomeClass $thing where { $_->can('stuff') }:
                 Str  $bar  = "apan",
                 Int :$baz! = 42 where { $_ % 2 == 0 } where { $_ > 10 } )

    # the invocant is called $thing, must be an instance of SomeClass and
           has to implement a 'stuff' method
    # $bar is positional, required, must be a string and defaults to "affe"
    # $baz is named, required, must be an integer, defaults to 42 and needs
    #      to be even and greater than 10

=head1 BUGS, CAVEATS AND NOTES

=head2 Fancy signatures

L<Parse::Method::Signatures> is used to parse the signatures. However, some
signatures that can be parsed by it aren't supported by this module (yet).

=head2 No source filter

While this module does rely on the hairy black magic of L<Devel::Declare> it
does not depend on a source filter. As such, it doesn't try to parse and
rewrite your source code and there should be no weird side effects.

Devel::Declare only effects compilation. After that, it's a normal subroutine.
As such, for all that hairy magic, this module is surprisingly stable.

=head2 What about regular subroutines?

L<Devel::Declare> cannot yet change the way C<sub> behaves. However, the
L<signatures|signatures> module can. Right now it only provides very basic
signatures, but it's extendable enough that plugging MooseX::Method::Signatures
signatures into that should be quite possible.

=head2 What about the return value?

Type constraints for return values can be declared using

  method foo (Int $x, Str $y) returns (Bool) { ... }

however, this feature only works with scalar return values and is still
considered to be experimental.

=head2 Interaction with L<Moose::Role>

=head3 Methods not seen by a role's C<requires>

Because the processing of the L<MooseX::Method::Signatures>
C<method> and the L<Moose> C<with> keywords are both
done at runtime, it can happen that a role will require
a method before it is declared (which will cause
Moose to complain very loudly and abort the program).

For example, the following will not work:

    # in file Canine.pm

    package Canine;

    use Moose;
    use MooseX::Method::Signatures;

    with 'Watchdog';

    method bark { print "Woof!\n"; }

    1;


    # in file Watchdog.pm

    package Watchdog;

    use Moose::Role;

    requires 'bark';  # will assert! evaluated before 'method' is processed

    sub warn_intruder {
        my $self = shift;
        my $intruder = shift;

        $self->bark until $intruder->gone;
    }

    1;


A workaround for this problem is to use C<with> only
after the methods have been defined.  To take our previous
example, B<Canine> could be reworked thus:

    package Canine;

    use Moose;
    use MooseX::Method::Signatures;

    method bark { print "Woof!\n"; }

    with 'Watchdog';

    1;


A better solution is to use L<MooseX::Declare> instead of plain
L<MooseX::Method::Signatures>. It defers application of roles until the end
of the class definition. With it, our example would becomes:


    # in file Canine.pm

    use MooseX::Declare;

    class Canine with Watchdog {
        method bark { print "Woof!\n"; }
    }

    1;

    # in file Watchdog.pm

    use MooseX::Declare;

    role Watchdog {
        requires 'bark';

        method warn_intruder ( $intruder ) {
            $self->bark until $intruder->gone;
        }
    }

    1;


=head3 I<Subroutine redefined> warnings

When composing a L<Moose::Role> into a class that uses
L<MooseX::Method::Signatures>, you may get a "Subroutine redefined"
warning. This happens when both the role and the class define a
method/subroutine of the same name. (The way roles work, the one
defined in the class takes precedence.) To eliminate this warning,
make sure that your C<with> declaration happens after any
method/subroutine declarations that may have the same name as a
method/subroutine within a role.

=head1 SEE ALSO

L<Method::Signatures::Simple>

L<Method::Signatures>

L<Perl6::Subs>

L<Devel::Declare>

L<Parse::Method::Signatures>

L<Moose>

=head1 AUTHOR

Florian Ragwitz E<lt>rafl@debian.orgE<gt>

With contributions from:

=over 4

=item Ash Berlin E<lt>ash@cpan.orgE<gt>

=item Hakim Cassimally E<lt>hakim.cassimally@gmail.comE<gt>

=item Jonathan Scott Duff E<lt>duff@pobox.comE<gt>

=item Kent Fredric E<lt>kentfredric@gmail.comE<gt>

=item Matt Kraai E<lt>kraai@ftbfs.orgE<gt>

=item Rhesa Rozendaal E<lt>rhesa@cpan.orgE<gt>

=item Ricardo SIGNES E<lt>rjbs@cpan.orgE<gt>

=item Steffen Schwigon E<lt>ss5@renormalist.netE<gt>

=item Yanick Champoux E<lt>yanick@babyl.dyndns.orgE<gt>

=back

=head1 COPYRIGHT AND LICENSE

Copyright (c) 2008, 2009  Florian Ragwitz

Code based on the tests for L<Devel::Declare>.

Documentation based on L<MooseX::Method> and L<Method::Signatures>.

Licensed under the same terms as Perl itself.

=cut
