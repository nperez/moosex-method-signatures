package TestClassTrait;
use Moose;
use MooseX::Method::Signatures;

use MXMSMoody;
use MXMSLabeled;

<<<<<<< HEAD:t/lib/TestClassTrait.pm
method method_with_trait(Str :$name!) is MXMSMoody {
=======
method method_with_trait(Str :$name!) is (MXMSMoody) {
>>>>>>> c19acca... Implement method traits using new strip_names_and_args from Devel::Declare:t/lib/TestClassTrait.pm

    return 1;
}

method method_with_two_traits() is (MXMSMoody, MXMSLabeled) {

    return 1;
}

method method_with_two_is_traits() is MXMSMoody is MXMSLabeled {

    return 1;
}

method method_with_two_is_param_traits() is MXMSMoody
    is MXMSLabeled(label => 'happy') {

    return 1;
}


no Moose;

1;
