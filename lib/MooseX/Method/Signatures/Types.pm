package MooseX::Method::Signatures::Types;
use warnings;
use strict;
use MooseX::Types -declare => [qw/ Injections PrototypeInjections Params /];
use MooseX::Types::Moose('Str', 'ArrayRef');
use MooseX::Types::Structured('Dict', 'Tuple', 'Optional');
use Parse::Method::Signatures;

subtype Injections,
    as ArrayRef[Str];

subtype PrototypeInjections,
    as Dict[declarator => Str, injections => Injections];

subtype Params,
    as ArrayRef[class_type('Parse::Method::Signatures::Param')];
1;
