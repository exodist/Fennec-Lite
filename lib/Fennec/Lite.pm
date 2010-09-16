package Fennec::Lite;
use strict;
use warnings;

use Test::Builder;
use Test::More;
use Carp qw/ croak /;
use List::Util qw/ shuffle /;
use B;

our $VERSION = '0.003';

our @USE_IF_PRESENT = qw/
    Test::Warn
    Test::Exception
    Fake::Thing
/;

our @EXPORT = qw/
    tests
    run_tests
    fennec_accessors
/;

fennec_accessors(qw/
    _tests
    load
    created_by
    seed
    random
/);

our $SINGLETON;
sub get { $SINGLETON }

sub import {
    my $class = shift;
    my %specs = @_;
    my $caller = caller;

    $specs{random} = 1 unless defined $specs{random};

    my $plan = $specs{plan} || (Test::More->can('done_testing') ? '' : 'no_plan');
    eval "package $caller; Test::More->import(" . ($plan ? 'tests => $plan' : '') . "); 1"
        || die $@;

    for my $pkg ( @USE_IF_PRESENT, @{ $specs{load} || [] }) {
        my $loaded = eval "package $caller; use $pkg; 1";
        my $error = $@;
        next if $loaded || $error =~ m/Can't locate [\w\d_\/\.]+\.pm in \@INC/;
        die $error;
    }

    if ( my $testing = $specs{testing}) {
        no strict 'refs';
        *{"$caller\::CLASS"} = sub { $testing };
        *{"$caller\::CLASS"} = \$testing;
    }

    if ( my $aliases = $specs{alias}) {
        $aliases = [ $aliases ] unless ref $aliases;
        for my $class ( @$aliases ) {
            eval "require $class; 1" || die $@;
            no strict 'refs';
            my $name = $class;
            $name =~ s/^.*:([^:]+)$/$1/;
            *{"$caller\::$name"} = sub { $class };
        }
    }

    if ( my $alias_map = $specs{alias_to}) {
        for my $name ( keys %$alias_map ) {
            my $class = $alias_map->{ $name };
            no strict 'refs';
            *{"$caller\::$name"} = sub { $class };
        }
    }

    for my $export ( @EXPORT ) {
        no strict 'refs';
        *{"$caller\::$export"} = $class->can( $export )
            || croak "$class does not export $export.";
    }

    $SINGLETON ||= $class->_new( %specs, created_by => $caller );
}

sub _new {
    my $class = shift;
    my %proto = @_;
    my @ltime = localtime(time);
    %proto = (
        _tests => [],
        seed => $ENV{FENNEC_SEED} || join( '', @ltime[5,4,3] ),
        %proto,
    );
    return bless( \%proto, $class );
}

sub tests {
    my $runner = __PACKAGE__->get;
    ( undef, undef, my $end_line ) = caller;
    my $name = shift;
    my %proto = ( @_ == 1 )
        ? ( method => $_[0] )
        : @_;

    $proto{ name } = $name if $name;
    $proto{ method } ||= $proto{ code } || $proto{ sub };
    $proto{ end_line } = $end_line;
    $proto{ start_line } = B::svref_2object( $proto{ method })->START->line;

    croak "You must name your test group"
        unless $proto{name};

    croak "You must provide a coderef as one of the following params 'method', 'code', or 'sub'."
        unless $proto{method};

    push @{$runner->_tests} => \%proto;
}

sub run_tests {
    my %params = @_;
    my $caller = caller;
    my $runner = __PACKAGE__->get;
    my $tests = $runner->_tests;
    my $pass = 1;
    my $TB = Test::Builder->new;
    my $item = $ENV{FENNEC_ITEM};

    my $invocant = $caller->can( 'new' )
        ? $caller->new( %params )
        : bless( \%params, $caller );

    srand( $runner->seed );
    $tests = [ shuffle @$tests ]
        if $runner->random;

    for my $test ( @$tests ) {
        my $method = $test->{method};
        my $name = $test->{name};

        if ( $item ) {
            if ( $item =~ m/^\d+$/ ) {
                next unless $test->{start_line} <= ($item + 1);
                next unless $test->{end_line} >= $item;
            }
            else {
                next unless $name eq $item;
            }
        }

        my ( $ret, $err ) = ( 1, "" );
        my $do_test = sub {
            $ret = eval { $method->( $invocant ); 1 };
            $err = $@;
        };

        my $reason;
        if ( $reason = $test->{ skip }) {
            note "Skipping: $name";
            $TB->skip( $reason );
        }
        elsif ( $reason = $test->{ todo }) {
            $TB->todo_start( $reason );
            $do_test->();
            $TB->todo_end;
        }
        else {
            $do_test->();
        }

        $ret = !$ret if $test->{ _invert_result };
        ok( $ret, "Test Group '$name' returned properly" );
        diag $err unless $ret;
        $pass &&= $ret;
    }

    $runner->_tests([]);
    return $pass;
}

sub fennec_accessors {
    my $caller = caller;
    for my $name ( @_ ) {
        my $sub = sub {
            my $self = shift;
            ( $self->{ $name }) = @_ if @_;
            return $self->{ $name };
        };
        no strict 'refs';
        *{"$caller\::$name"} = $sub;
    }
}

1;


=head1 NAME

Fennec::Lite - Minimalist Fennec, the commonly used bits.

=head1 DESCRIPTION

L<Fennec> does a ton, but it may be hard to adopt it all at once. It also is a
large project, and has not yet been fully split into component projects.
Fennec::Lite takes a minimalist approach to do for Fennec what Mouse does for
Moose.

Fennec::Lite is a single module file with no non-core dependencies. It can
easily be used by any project, either directly, or by copying it into your
project. The file itself is less than 200 lines of code at the time of this
writing, that includes whitespace.

This module does not cover any of the more advanced features such as result
capturing or SPEC workflows. This module only covers test grouping and group
randomization. You can also use the FENNEC_ITEM variable with a group name or
line number to run a specific test group only. Test::Builder is used under the
hood for TAP output.

=head1 SYNOPSIS

=head2 SIMPLE

    #!/usr/bin/perl
    use strict;
    use warnings;

    # Brings in Test::More for us.
    use Fennec::Lite;

    tests good => sub {
        ok( 1, "A good test" );
    };

    # You most call run_tests() after declaring your tests.
    run_tests();
    done_testing();

=head2 ADVANCED

    #!/usr/bin/perl
    use strict;
    use warnings;

    use Fennec::Lite
        plan => 8,
        random => 1,
        testing => 'My::Class',
        alias => [
            'My::Class::ThingA'
        ],
        alias_to => {
            TB => 'My::Class::ThingB',
        };

    # Quickly create get/set accessors
    fennec_accessors qw/ construction_string /;

    # Create a constructor for our test class.
    sub new {
        my $class = shift;
        my $string = @_;
        return bless({ construction_string => $string }, $class );
    }

    tests good => sub {
        # Get $self. Created with new()
        my $self = shift;
        $self->isa_ok( __PACKAGE__ );
        is(
            $self->construction_string,
            "This is the construction string",
            "Constructed properly"
        );
        ok( 1, "A good test" );
    };

    tests "todo group" => (
        todo => "This will fail",
        code => sub { ok( 0, "false value" )},
    );

    tests "skip group" => (
        skip => "This will fail badly",
        sub => sub { die "oops" },
    );

    run_tests( "This is the construction string" );

=head1 IMPORTED FOR YOU

When you use Fennec::Lite, L<Test::More> is automatically imported for you. In
addition L<Test::Warn> and L<Test::Exception> will also be loaded, but only if
they are installed.

=head1 IMPORT ARGUMENTS

    use Fennec::Lite %ARGS

=over 4

=item plan => 'no_plan' || $count

Plan to pass into Test::More.

=item random => $bool

True by default. When true test groups will be run in random order.

=item testing => $CLASS_NAME

Declare what class you ore testing. Provides $CLASS and CLASS(), both of which
are simply the name of the class being tested.

=item alias => @PACKAGES

Create alias functions your the given package. An alias is a function that
returns the package name. The aliases will be named after the last part of the
package name.

=item alias_to => { $ALIAS => $PACKAGE, ... }

Define aliases, keys are alias names, values are tho package names they should
return.

=back

=head1 RUNNING IN RANDOM ORDER

By default test groups will be run in a random order. The random seed is the
current date (YYYYMMDD). This is used so that the order does not change on the
day you are editing your code. However the ardor will change daily allowing for
automated testing to find order dependent failures.

You can manually set the random seed to reproduce a failure. The FENNEC_SEED
environment variable will be used as the seed when it is present.

    $ FENNEC_SEED="20100915" prove -I lib -v t/*.t

=head1 RUNNING SPECIFIC GROUPS

You can use the FENNEC_ITEM variable with a group name or line number to run a
specific test group only.

    $ FENNEC_ITEM="22" prove -I lib -v t/MyTest.t
    $ FENNEC_ITEM="Test Group A" prove -I lib -v t/MyTest.t

This can easily be integrated into an editor such as vim or emacs.

=head1 EXPORTED FUNCTIONS

=over 4

=item tests $name => $coderef,

=item tests $name => ( code => $coderef, todo => $reason )

=item tests $name => ( code => $coderef, skip => $reason )

=item tests $name => ( sub => $coderef )

=item tests $name => ( method => $coderef )

Declare a test group. The first argument must always be the test group name. In
the 2 part form the second argument must be a coderef. In the multi-part form
you may optionally declare the group as todo, or as a skip. A coderef must
always be provided, in multi-part form you may use the code, method, or sub
params for this purpose, they are all the same.

=item run_tests( %params )

Instantiate an instance of the test class, passing %params to the constructor.
If no constructor is present a default is used. All tests that have been added
will be run. All tests will be cleared, you may continue to declare tests and
call run_tests again to run the new tests.

=item fennec_accessors( @NAMES )

Quickly generate get/set accessors for your test class. You could alternatively
do it manually or use L<Moose>.

=back

=head1 FENNEC PROJECT

This module is part of the Fennec project. See L<Fennec> for more details.
Fennec is a project to develop an extensible and powerful testing framework.
Together the tools that make up the Fennec framework provide a potent testing
environment.

The tools provided by Fennec are also useful on their own. Sometimes a tool
created for Fennec is useful outside the greater framework. Such tools are
turned into their own projects. This is one such project.

=over 2

=item L<Fennec> - The core framework

The primary Fennec project that ties them all together.

=back

=head1 AUTHORS

Chad Granum L<exodist7@gmail.com>

=head1 COPYRIGHT

Copyright (C) 2010 Chad Granum

Fennec-Lite is free software; Standard perl license.

Fennec-Lite is distributed in the hope that it will be useful, but WITHOUT ANY
WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS
FOR A PARTICULAR PURPOSE.  See the license for more details.
