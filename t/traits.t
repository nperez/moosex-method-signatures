use strict;
use warnings;
use Test::More tests => 20;

use FindBin;
use lib "$FindBin::Bin/lib";

use TestClassTrait;

use Moose::Util qw(does_role);

my $c = TestClassTrait->new;

my $method = $c->meta->get_method('method_with_trait');
isa_ok($method, 'MooseX::Method::Signatures::Meta::Method');

ok($method->has_traits, 'method has traits');
is($method->traits->[0], 'MXMSMoody', 'traits attribute returns the right string');
ok(does_role($method, 'MXMSMoody'), 'method has MXMSMoody trait');
cmp_ok($method->mood, 'eq', 'happy', 'method is happy');

my $tt_method = $c->meta->get_method('method_with_two_traits');
isa_ok($tt_method, 'MooseX::Method::Signatures::Meta::Method');

ok($tt_method->has_traits, 'method has traits');
is_deeply($tt_method->traits, ['MXMSMoody', 'MXMSLabeled'], 'traits attribute returns the right arrayref');
ok(does_role($tt_method, 'MXMSMoody'), 'method has MXMSMoody trait');
ok(does_role($tt_method, 'MXMSLabeled'), 'method has MXMSLabeled trait');

my $twois_method = $c->meta->get_method('method_with_two_is_traits');
ok($twois_method->has_traits, 'method has traits');
is_deeply($twois_method->traits, ['MXMSMoody', 'MXMSLabeled'], 'traits attribute returns the right arrayref');
ok(does_role($twois_method, 'MXMSMoody'), 'two is method has MXMSMoody trait');
ok(does_role($twois_method, 'MXMSLabeled'), 'two is method has MXMSLabeled trait');

my $param_method = $c->meta->get_method('method_with_two_is_param_traits');
ok($param_method->has_traits, 'method has traits');
is_deeply($param_method->traits, ['MXMSMoody', 'MXMSLabeled'], 'traits attribute returns the right arrayref');
ok(does_role($twois_method, 'MXMSMoody'), 'param method has MXMSMoody trait');
ok(does_role($twois_method, 'MXMSLabeled'), 'param method has MXMSLabeled trait');

SKIP: {
	skip 'attributes not supported yet', 2;
	ok($param_method->has_label, 'method has label');
	cmp_ok($param_method->label, 'eq', 'happy', 'label is happy');
}
