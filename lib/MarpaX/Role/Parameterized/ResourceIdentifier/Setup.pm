use strict;
use warnings FATAL => 'all';

package MarpaX::Role::Parameterized::ResourceIdentifier::Setup;
use Moo;
use Types::Standard -all;

# ABSTRACT: Resource Identifier setup

# VERSION

# AUTHORITY

no warnings 'once';
#
# The followings have a default value
#
sub marpa_trace_terminals      { $MarpaX::RI::MARPA_TRACE_TERMINALS   // 0            }
sub marpa_trace_values         { $MarpaX::RI::MARPA_TRACE_VALUES      // 0            }
sub uri_compat                 { $MarpaX::RI::URI_COMPAT              // 0            }
sub plugins_dirname            { $MarpaX::RI::PLUGINS_DIRNAME         // 'Plugins'    }
sub impl_dirname               { $MarpaX::RI::IMPL_DIRNAME            // 'Impl'       }
sub can_scheme_methodname      { $MarpaX::RI::CAN_SCHEME_METHODNAME   // 'can_scheme' }
#
# The followings can return undef
#
sub abs_remote_leading_dots    { __PACKAGE__->uri_compat() ?   $URI::ABS_REMOTE_LEADING_DOTS   :   $MarpaX::RI::ABS_REMOTE_LEADING_DOTS    }
sub remove_dot_segments_strict { __PACKAGE__->uri_compat() ? ! $URI::ABS_ALLOW_RELATIVE_SCHEME : ! $MarpaX::RI::ABS_ALLOW_RELATIVE_SCHEME  }

with 'MooX::Singleton';

1;
