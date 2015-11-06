use strict;
use warnings FATAL => 'all';

package MarpaX::Role::Parameterized::ResourceIdentifier::BNF;
use Carp qw/croak/;
use Class::Method::Modifiers qw/install_modifier/;
use Data::Dumper;
use Encode 2.21 qw/find_encoding encode decode/; # 2.21 for mime_name support
use Marpa::R2;
use MarpaX::RFC::RFC3629;
use MarpaX::Role::Parameterized::ResourceIdentifier::MarpaTrace;
use MarpaX::Role::Parameterized::ResourceIdentifier::Setup;
use MarpaX::Role::Parameterized::ResourceIdentifier::Types qw/Common Generic/;
use Moo::Role;
use MooX::Role::Logger;
use MooX::HandlesVia;
use MooX::Role::Parameterized;
use Role::Tiny;
use Scalar::Util qw/blessed/;
use Type::Params qw/compile/;
use Types::Encodings qw/Bytes/;
use Types::Standard -all;
use Types::TypeTiny qw/StringLike/;
use Try::Tiny;
use constant {
  RAW                         =>  0, # Concat: yes, Normalize: no,  Convert: no
  URI_CONVERTED               =>  1, # Concat: yes, Normalize: no,  Convert: yes
  IRI_CONVERTED               =>  2, # Concat: yes, Normalize: no,  Convert: yes
  CASE_NORMALIZED             =>  3, # Concat: yes, Normalize: yes, Convert: no
  CHARACTER_NORMALIZED        =>  4, # Concat: yes, Normalize: yes, Convert: no
  PERCENT_ENCODING_NORMALIZED =>  5, # Concat: yes, Normalize: yes, Convert: no
  PATH_SEGMENT_NORMALIZED     =>  6, # Concat: yes, Normalize: yes, Convert: no
  SCHEME_BASED_NORMALIZED     =>  7, # Concat: yes, Normalize: yes, Convert: no
  PROTOCOL_BASED_NORMALIZED   =>  8, # Concat: yes, Normalize: yes, Convert: no
  _COUNT                      =>  9
};
use overload (
              '""'     => sub { $_[0]->input },
              '=='     => sub { $_[0]->output_by_indice($_[0]->indice_normalized) eq $_[1]->output_by_indice($_[1]->indice_normalized) },
              '!='     => sub { $_[0]->output_by_indice($_[0]->indice_normalized) ne $_[1]->output_by_indice($_[1]->indice_normalized) },
              fallback => 1,
             );


our $MAX                         = _COUNT - 1;
our $indice_concatenate_start    = RAW;
our $indice_concatenate_end      = PROTOCOL_BASED_NORMALIZED;
our $indice_normalizer_start     = CASE_NORMALIZED;
our $indice_normalizer_end       = PROTOCOL_BASED_NORMALIZED;
our $indice_converter_start      = URI_CONVERTED;
our $indice_converter_end        = IRI_CONVERTED;
our @normalizer_names = qw/case_normalizer
                           character_normalizer
                           percent_encoding_normalizer
                           path_segment_normalizer
                           scheme_based_normalizer
                           protocol_based_normalizer/;
our @converter_names = qw/uri_converter
                          iri_converter/;
our @ucs_mime_name = map { find_encoding($_)->mime_name } qw/UTF-8 UTF-16 UTF-16BE UTF-16LE UTF-32 UTF-32BE UTF-32LE/;
# ------------------------------------------------------------
# Explicit slots for all supported attributes in input, scheme
# is explicitely ignored, it is handled only by _top
# ------------------------------------------------------------
has input                   => ( is => 'rwp', isa => StringLike                            );
has has_recognized_scheme   => ( is => 'ro',  isa => Bool,        default => sub {   !!0 } );
has is_character_normalized => ( is => 'rwp', isa => Bool,        default => sub {   !!1 } );
# ----------------------------------------------------------------------------
# Slots that implementations should 'around' on the builders for customization
# ----------------------------------------------------------------------------
has pct_encoded             => ( is => 'ro',  isa => Str|Undef,   lazy => 1, builder => 'build_pct_encoded' );
has reserved                => ( is => 'ro',  isa => RegexpRef,   lazy => 1, builder => 'build_reserved' );
has unreserved              => ( is => 'ro',  isa => RegexpRef,   lazy => 1, builder => 'build_unreserved' );
has default_port            => ( is => 'ro',  isa => Int|Undef,   lazy => 1, builder => 'build_default_port' );
has reg_name_is_domain_name => ( is => 'ro',  isa => Bool,        lazy => 1, builder => 'build_reg_name_is_domain_name' );
__PACKAGE__->_generate_attributes('normalizer', $indice_normalizer_start, $indice_normalizer_end, @normalizer_names);
__PACKAGE__->_generate_attributes('converter', $indice_converter_start, $indice_converter_end, @converter_names);
# ----------------------------------------------------------------------------
# Parsing result: this is the output after latest of the normalization steps
# ----------------------------------------------------------------------------
has output                  => ( is => 'rwp', isa => Str                                 );

# --------------
# Internal slots
# --------------
has _structs                => ( is => 'rw',  isa => ArrayRef[Object] );
has _indice_description     => ( is => 'ro',  isa => ArrayRef[Str], default => sub {
                                   [
                                    'Raw value                        ',
                                    'URI converted value              ',
                                    'IRI converted value              ',
                                    'Case normalized value            ',
                                    'Character normalized value       ',
                                    'Percent encoding normalized value',
                                    'Path segment normalized value    ',
                                    'Scheme based normalized value    ',
                                    'Protocol based normalized value  '
                                   ]
                                 }
                               );

# =============================================================================
# We want parsing to happen immeidately AFTER object was build and then at
# every input reconstruction
# =============================================================================
our $setup                = MarpaX::Role::Parameterized::ResourceIdentifier::Setup->new;
our $check_BUILDARGS      = compile(StringLike|HashRef);
our $check_BUILDARGS_Dict = compile(slurpy Dict[
                                                input                   => Optional[StringLike],
                                                octets                  => Optional[Bytes],
                                                encoding                => Optional[Str],
                                                decode_strategy         => Optional[Any],
                                                is_character_normalized => Optional[Bool]
                                               ]);
sub BUILDARGS {
  my ($class, $arg) = @_;

  my ($first_arg) = $check_BUILDARGS->($arg);

  my $input;
  my $is_character_normalized;

  if (StringLike->check($first_arg)) {
    $input = "$first_arg";
  } else {
    my ($params)    = $check_BUILDARGS_Dict->(%{$arg});

    croak 'Please specify either input or octets'                if (! exists($params->{input})  && ! exists($params->{octets}));
    croak 'Please specify only one of input or octets, not both' if (  exists($params->{input})  &&   exists($params->{octets}));
    croak 'Please specify encoding'                              if (  exists($params->{octets}) && ! exists($params->{encoding}));
    if (exists($params->{input})) {
      $input = "$params->{input}";
    } else {
      my $octets          = $params->{octets};
      my $encoding        = $params->{encoding};
      my $decode_strategy = $params->{decode_strategy} // Encode::FB_CROAK;
      if (exists($params->{is_character_normalized})) {
        $is_character_normalized = $params->{is_character_normalized};
      } else {
        my $enc_mime_name = find_encoding($encoding)->mime_name;
        $is_character_normalized = grep { $enc_mime_name eq $_ } @ucs_mime_name;
      }
      #
      # Encode::encode will croak by itself if decode_strategy is not ok
      #
      $input = decode($encoding, $octets, $decode_strategy);
    }
  }

  if ($setup->uri_compat) {
    #
    # Copy from URI:
    # Get rid of potential wrapping
    #
    $input =~ s/^<(?:URL:)?(.*)>$/$1/;
    $input =~ s/^"(.*)"$/$1/;
    $input =~ s/^\s+//;
    $input =~ s/\s+$//;
  }

  my %args = ( input => $input );
  $args{is_character_normalized} = $is_character_normalized if ! Undef->check($is_character_normalized);

  \%args
}

sub BUILD {
  my ($self) = @_;
  $self->_parse;
  after input => sub { $self->_parse }
}
# =============================================================================
# Parameter validation
# =============================================================================
our $check_params = compile(
                            slurpy
                            Dict[
                                 whoami      => Str,
                                 type        => Enum[qw/common generic/],
                                 bnf         => Str,
                                 reserved    => RegexpRef,
                                 unreserved  => RegexpRef,
                                 pct_encoded => Str|Undef,
                                 mapping     => HashRef[Str]
                                ]
                           );

# =============================================================================
# Parameterized role
# =============================================================================
#
# For Marpa optimisation
#
my %registrations = ();
my %context = ();

role {
  my $params = shift;
  #
  # -----------------------
  # Sanity checks on params
  # -----------------------
  my ($hash_ref)  = HashRef->($params);
  my ($PARAMS)    = $check_params->(%{$hash_ref});

  my $whoami      = $PARAMS->{whoami};
  my $type        = $PARAMS->{type};
  my $bnf         = $PARAMS->{bnf};
  my $mapping     = $PARAMS->{mapping};

  #
  # Make sure $whoami package is doing MooX::Role::Logger is not already
  #
  Role::Tiny->apply_roles_to_package($whoami, 'MooX::Role::Logger') unless $whoami->DOES('MooX::Role::Logger');
  my $action_full_name = sprintf('%s::_action', $whoami);
  #
  # Push on-the-fly the action name
  # This will natively croak if the BNF would provide another hint for implementation
  #
  $bnf = ":default ::= action => $action_full_name\n$bnf";

  my $is_common   = $type eq 'common';
  #
  # A bnf package must provide correspondance between grammar symbols
  # and fields in a structure, in the form "<xxx>" => yyy.
  # The structure depend on the type: Common or Generic
  #
  my %fields = ();
  my $struct_new = $is_common ? Common->new : Generic->new;
  my $struct_class = blessed($struct_new);
  my @fields = $struct_new->FIELDS;
  map { $fields{$_} = 0 } @fields;
  while (my ($key, $value) = each %{$mapping}) {
    croak "[$type] symbol $key must be in the form <...>"
      unless $key =~ /^<.*>$/;
    croak "[$type] mapping of unknown field $value"
      unless exists $fields{$value};
    $fields{$value}++;
  }
  my @not_found = grep { ! $fields{$_} } keys %fields;
  croak "[$type] Unmapped fields: @not_found" unless ! @not_found;

  # -----
  # Setup
  # -----
  my $marpa_trace_terminals = $setup->marpa_trace_terminals;
  my $marpa_trace_values    = $setup->marpa_trace_values;
  my $marpa_trace           = $setup->marpa_trace;
  my $uri_compat            = $setup->uri_compat;

  # -------
  # Logging
  # -------
  #
  # In any case, we want Marpa to be "silent", unless explicitely traced
  #
  my $trace;
  open(my $trace_file_handle, ">", \$trace) || croak "[$type] Cannot open trace filehandle, $!";
  local $MarpaX::Role::Parameterized::ResourceIdentifier::MarpaTrace::bnf_package = $whoami;
  tie ${$trace_file_handle}, 'MarpaX::Role::Parameterized::ResourceIdentifier::MarpaTrace';

  # ---------------------------------------------------------------------
  # This stub will be the one doing the real work, called by Marpa action
  # ---------------------------------------------------------------------
  #
  my %MAPPING = %{$mapping};
  my $args2array_sub = sub {
    my ($self, $criteria, @args) = @_;
    my $rc = [ ('') x _COUNT ];
    #
    # Concatenate
    #
    foreach my $irc ($indice_concatenate_start..$indice_concatenate_end) {
      do { $rc->[$irc] .= ref($args[$_]) ? $args[$_]->[$irc] : $args[$_] } for (0..$#args)
    }
    #
    # Normalize
    #
    my $current = $rc->[$indice_normalizer_start];
    do { $rc->[$_] = $current = $MarpaX::Role::Parameterized::ResourceIdentifier::BNF::normalizer_wrapper->[$_]->($self, $criteria, $current) } for ($indice_normalizer_start..$indice_normalizer_end);
    #
    # Convert
    #
    do { $rc->[$_] = $MarpaX::Role::Parameterized::ResourceIdentifier::BNF::converter_wrapper->[$_]->($self, $criteria, $rc->[$_]) } for ($indice_converter_start..$indice_converter_end);

    $rc
  };
  #
  # Parse method installed directly in the BNF package
  #
  my $grammar = Marpa::R2::Scanless::G->new({source => \$bnf});
  my %recognizer_option = (
                           trace_terminals   => $marpa_trace_terminals,
                           trace_values      => $marpa_trace_values,,
                           trace_file_handle => $trace_file_handle,
                           ranking_method    => 'high_rule_only',
                           grammar           => $grammar
                          );
  #
  # Marpa optimisation: we cache the registrations. At every recognizer's value() call
  # the actions are checked. But this is static information in our case
  #
  install_modifier($whoami, 'fresh', '_parse',
                   sub {
                     my ($self) = @_;

                     my $input = $self->input;

                     my $r = Marpa::R2::Scanless::R->new(\%recognizer_option);
                     #
                     # For performance reason, cache all $self-> accesses
                     #
                     local $MarpaX::Role::Parameterized::ResourceIdentifier::BNF::_structs           = $self->{_structs} = [map { $struct_class->new } 0..$MAX];
                     local $MarpaX::Role::Parameterized::ResourceIdentifier::BNF::normalizer_wrapper = $self->_normalizer_wrapper;
                     local $MarpaX::Role::Parameterized::ResourceIdentifier::BNF::converter_wrapper  = $self->_converter_wrapper;
                     #
                     # A very special case is the input itself, before the parsing
                     # We want to apply eventual normalizers and converters on it.
                     # To identify this special, $field and $lhs are both the
                     # empty string, i.e. a situation that can never happen during
                     # parsing
                     #
                     # $self->_logger->debugf('%s: %s', $whoami, Data::Dumper->new([$input], ['input                            '])->Dump);
                     #
                     # The normalization ladder
                     #
                     do { $input = $MarpaX::Role::Parameterized::ResourceIdentifier::BNF::normalizer_wrapper->[$_]->($self, '', $input, '') } for ($indice_normalizer_start..$indice_normalizer_end);
                     # $self->_logger->debugf('%s: %s', $whoami, Data::Dumper->new([$input], ['Normalized input                 '])->Dump);
                     #
                     # The converters. Every entry is independant.
                     #
                     do { $input = $MarpaX::Role::Parameterized::ResourceIdentifier::BNF::converter_wrapper->[$_]->($self, '', $input, '') } for ($indice_converter_start..$indice_converter_end);
                     # $self->_logger->debugf('%s: %s', $whoami, Data::Dumper->new([$input], ['Converted input                  '])->Dump);
                     #
                     # Parse (may croak)
                     #
                     $r->read(\$input);
                     croak "[$type] Parse of the input is ambiguous" if $r->ambiguous;
                     #
                     # Check result
                     #
                     # Marpa optimisation: we cache the registrations. At every recognizer's value() call
                     # the actions are checked. But this is static information in our case
                     #
                     my $registrations = $registrations{$whoami};
                     if (defined($registrations)) {
                       $r->registrations($registrations);
                     }
                     my $value_ref = $r->value($self);
                     if (! defined($registrations)) {
                       $registrations{$whoami} = $r->registrations();
                     }
                     # croak "[$type] No parse tree value" unless Ref->check($value_ref);
                     #
                     # This will croak natively if this is not a reference
                     #
                     my $value = ${$value_ref};
                     # croak "[$type] Invalid parse tree value" unless ArrayRef->check($value);
                     #
                     # Store result
                     #
                     do { $self->{_structs}->[$_]->{output} = $value->[$_] } for (0..$MAX);
                     $self->{output} = $self->{_structs}->[$indice_normalizer_end]->{output}
                   }
                  );
  #
  # Inject the action
  #
  $context{$whoami} = {};
  install_modifier($whoami, 'fresh', '_action',
                   sub {
                     my ($self, @args) = @_;
                     my ($lhs, @rhs) = @{$context{$whoami}->{$Marpa::R2::Context::rule}
                                           //=
                                             do {
                                               my $slg = $Marpa::R2::Context::slg;
                                               my @rules = map { $slg->symbol_display_form($_) } $slg->rule_expand($Marpa::R2::Context::rule);
                                               $rules[0] = "<$rules[0]>" if (substr($rules[0], 0, 1) ne '<');
                                               \@rules
                                             }
                                           };
                     # $self->_logger->tracef('%s: %s ::= %s', $whoami, $lhs, join(' ', @rhs));
                     my $field = $mapping->{$lhs};
                     # $self->_logger->tracef('%s:   %s[IN] %s', $whoami, $field || $lhs || '', \@args);
                     my $criteria = $field || $lhs;
                     my $array_ref = $self->$args2array_sub($criteria, @args);
                     # $self->_logger->tracef('%s:   %s[OUT] %s', $whoami, $field || $lhs || '', $array_ref);
                     #
                     # In the action, for a performance issue, I use defined() instead of ! Undef->check()
                     #
                     if (defined $field) {
                       #
                       # For performance reason, because we KNOW to what we are talking about
                       # we use explicit push() and set instead of the accessors
                       #
                       if ($field eq 'segments') {
                         #
                         # Segments is special
                         #
                         push(@{$MarpaX::Role::Parameterized::ResourceIdentifier::BNF::_structs->[$_]->{segments}}, $array_ref->[$_]) for (0..$MAX)
                       } else {
                         $MarpaX::Role::Parameterized::ResourceIdentifier::BNF::_structs->[$_]->{$field} = $array_ref->[$_] for (0..$MAX)
                       }
                     }
                     $array_ref
                   }
                  );
  # ----------------------------------------------------
  # The builders that the implementation should 'around'
  # ----------------------------------------------------
  install_modifier($whoami, 'fresh', 'build_pct_encoded'              => sub { $PARAMS->{pct_encoded} });
  install_modifier($whoami, 'fresh', 'build_reserved'                 => sub {    $PARAMS->{reserved} });
  install_modifier($whoami, 'fresh', 'build_unreserved'               => sub {  $PARAMS->{unreserved} });
  install_modifier($whoami, 'fresh', 'build_is_character_normalized'  => sub {                    !!1 });
  install_modifier($whoami, 'fresh', 'build_default_port'             => sub {                  undef });
  install_modifier($whoami, 'fresh', 'build_reg_name_is_domain_name'  => sub {                    !!0 });
  foreach (@normalizer_names, @converter_names) {
    install_modifier($whoami, 'fresh', "build_$_"                     => sub {              return {} });
  }
};
# =============================================================================
# Instance methods
# =============================================================================
sub struct_by_type           { $_[0]->_structs->[$_[0]->indice($_[1])] }
sub output_by_type           { $_[0]->struct_by_type($_[1])->output }
sub struct_by_indice         { $_[0]->_structs->[$_[1]] }
sub output_by_indice         { $_[0]->struct_by_indice($_[1])->output }
sub abs {
  my ($self, $base) = @_;
  #
  # Do nothing if $self is already absolute
  #
  my $self_struct = $self->_structs->[$self->indice_raw];
  return $self if (! Undef->check($self_struct->scheme));
  #
  # https://tools.ietf.org/html/rfc3986
  #
  # 5.2.1.  Pre-parse the Base URI
  #
  # The base URI (Base) is ./.. parsed into the five main components described in
  # Section 3.  Note that only the scheme component is required to be
  # present in a base URI; the other components may be empty or
  # undefined.  A component is undefined if its associated delimiter does
  # not appear in the URI reference; the path component is never
  # undefined, though it may be empty.
  #
  my $base_ri = (blessed($base) && $base->does(__PACKAGE__)) ? $base : blessed($self)->new($base);
  my $base_struct = $base_ri->_structs->[$base_ri->indice_raw];
  #
  # This work only if $base is absolute and ($self, $base) support the generic syntax
  #
  croak "$base is not absolute"            unless ! Undef->check($base_struct->scheme);
  croak "$self must do the generic syntax" unless Generic->check($self_struct);
  croak "$base must do the generic syntax" unless Generic->check($base_struct);
  my %Base = (
              scheme    => $base_struct->scheme,
              authority => $base_struct->authority,
              path      => $base_struct->path,
              query     => $base_struct->query,
              fragment  => $base_struct->fragment
             );
  #
  #   Normalization of the base URI, as described in Sections 6.2.2 and
  # 6.2.3, is optional.  A URI reference must be transformed to its
  # target URI before it can be normalized.
  #
  # 5.2.2.  Transform References
  #
  #
  # -- The URI reference is parsed into the five URI components
  #
  #
  # --
  # (R.scheme, R.authority, R.path, R.query, R.fragment) = parse(R);
  #
  my %R = (
           scheme    => $self_struct->scheme,
           authority => $self_struct->authority,
           path      => $self_struct->path,
           query     => $self_struct->query,
           fragment  => $self_struct->fragment
          );
  #
  # -- A non-strict parser may ignore a scheme in the reference
  # -- if it is identical to the base URI's scheme.
  # --
  # if ((! $strict) && ($R{scheme} eq $Base{scheme})) {
  #   $R{scheme} = undef;
  # }
  my %T = ();
  if (! Undef->check($R{scheme})) {
    $T{scheme}    = $R{scheme};
    $T{authority} = $R{authority};
    $T{path}      = __PACKAGE__->remove_dot_segments($R{path});
    $T{query}     = $R{query};
  } else {
    if (! Undef->check($R{authority})) {
      $T{authority} = $R{authority};
      $T{path}      = __PACKAGE__->remove_dot_segments($R{path});
      $T{query}     = $R{query};
    } else {
      if (! length($R{path})) {
        $T{path} = $Base{path};
        $T{query} = Undef->check($R{query}) ? $Base{query} : $R{query}
      } else {
        if (substr($R{path}, 0, 1) eq '/') {
          $T{path} = __PACKAGE__->remove_dot_segments($R{path})
        } else {
          $T{path} = __PACKAGE__->_merge(\%Base, \%R);
          $T{path} = __PACKAGE__->remove_dot_segments($T{path});
        }
        $T{query} = $R{query};
      }
      $T{authority} = $Base{authority};
    }
    $T{scheme} = $Base{scheme};
  }

  $T{fragment} = $R{fragment};

  blessed($self)->new(__PACKAGE__->_recompose(\%T))
}
# =============================================================================
# Class methods
# =============================================================================
sub indice_raw                         {                            RAW }
sub indice_case_normalized             {                CASE_NORMALIZED }
sub indice_character_normalized        {           CHARACTER_NORMALIZED }
sub indice_percent_encoding_normalized {    PERCENT_ENCODING_NORMALIZED }
sub indice_path_segment_normalized     {        PATH_SEGMENT_NORMALIZED }
sub indice_scheme_based_normalized     {        SCHEME_BASED_NORMALIZED }
sub indice_protocol_based_normalized   {      PROTOCOL_BASED_NORMALIZED }
sub indice_uri_converted               {                  URI_CONVERTED }
sub indice_iri_converted               {                  IRI_CONVERTED }
sub indice_normalized                  {         $indice_normalizer_end }
sub indice {
  my ($class, $what) = @_;

  croak "Invalid undef argument" if (Undef->check($what));

  if    ($what eq 'RAW'                        ) { return                         RAW }
  elsif ($what eq 'URI_CONVERTED'              ) { return               URI_CONVERTED }
  elsif ($what eq 'IRI_CONVERTED'              ) { return               IRI_CONVERTED }
  elsif ($what eq 'CASE_NORMALIZED'            ) { return             CASE_NORMALIZED }
  elsif ($what eq 'CHARACTER_NORMALIZED'       ) { return        CHARACTER_NORMALIZED }
  elsif ($what eq 'PERCENT_ENCODING_NORMALIZED') { return PERCENT_ENCODING_NORMALIZED }
  elsif ($what eq 'PATH_SEGMENT_NORMALIZED'    ) { return     PATH_SEGMENT_NORMALIZED }
  elsif ($what eq 'SCHEME_BASED_NORMALIZED'    ) { return     SCHEME_BASED_NORMALIZED }
  elsif ($what eq 'PROTOCOL_BASED_NORMALIZED'  ) { return   PROTOCOL_BASED_NORMALIZED }
  else                                           { croak "Invalid argument $what"     }
}

sub percent_encode {
  my ($class, $string, $regexp) = @_;

  my $encoded = $string;
  $encoded =~ s!$regexp!
    {
     #
     # ${^MATCH} is a read-only variable
     # and Encode::encode is affecting $match -;
     #
     my $match = ${^MATCH};
     join('',
          map {
            '%' . uc(unpack('H2', $_))
          } split(//, Encode::encode('UTF-8', $match, Encode::FB_CROAK))
         )
    }
    !egp;
  $encoded
}

sub _merge {
  my ($class, $base, $ref) = @_;
  #
  # https://tools.ietf.org/html/rfc3986
  #
  # 5.2.3.  Merge Paths
  #
  # If the base URI has a defined authority component and an empty
  # path, then return a string consisting of "/" concatenated with the
  # reference's path; otherwise,
  #
  if (! Undef->check($base->{authority}) && ! length($base->{path})) {
    return '/' . $ref->{path};
  }
  #
  # return a string consisting of the reference's path component
  # appended to all but the last segment of the base URI's path (i.e.,
  # excluding any characters after the right-most "/" in the base URI
  # path, or excluding the entire base URI path if it does not contain
  # any "/" characters).
  #
  else {
    my $base_path = $base->{path};
    if ($base_path !~ /\//) {
      $base_path = '';
    } else {
      $base_path =~ s/\/[^\/]*\z/\//;
    }
    return $base_path . $ref->{path};
  }
}

sub _recompose {
  my ($class, $T) = @_;
  #
  # https://tools.ietf.org/html/rfc3986
  #
  # 5.3.  Component Recomposition
  #
  # We are called only by abs(), so we are sure to have a hash reference in argument
  #
  #
  my $result = '';
  $result .=        $T->{scheme} . ':' if (! Undef->check($T->{scheme}));
  $result .= '//' . $T->{authority}    if (! Undef->check($T->{authority}));
  $result .=        $T->{path};
  $result .= '?'  . $T->{query}        if (! Undef->check($T->{query}));
  $result .= '#'  . $T->{fragment}     if (! Undef->check($T->{fragment}));

  $result
}

sub remove_dot_segments {
  my ($class, $input) = @_;
  #
  # https://tools.ietf.org/html/rfc3986
  #
  # 5.2.4.  Remove Dot Segments
  #
  # 1.  The input buffer is initialized with the now-appended path
  # components and the output buffer is initialized to the empty
  # string.
  #
  my $output = '';

  # my $i = 0;
  # my $step = ++$i;
  # my $substep = '';
  # printf STDERR "%-10s %-30s %-30s\n", "STEP", "OUTPUT BUFFER", "INPUT BUFFER";
  # printf STDERR "%-10s %-30s %-30s\n", "$step$substep", $output, $input;
  # $step = ++$i;
  #
  # 2.  While the input buffer is not empty, loop as follows:
  #
  while (length($input)) {
    #
    # A. If the input buffer begins with a prefix of "../" or "./",
    #    then remove that prefix from the input buffer; otherwise,
    #
    if (index($input, '../') == 0) {
      substr($input, 0, 3, '')
      # $substep = 'A';
    }
    elsif (index($input, './') == 0) {
      substr($input, 0, 2, '')
      # $substep = 'A';
    }
    #
    # B. if the input buffer begins with a prefix of "/./" or "/.",
    #    where "." is a complete path segment, then replace that
    #    prefix with "/" in the input buffer; otherwise,
    #
    elsif (index($input, '/./') == 0) {
      substr($input, 0, 3, '/')
      # $substep = 'B';
    }
    elsif ($input =~ /^\/\.(?:[\/]|\z)/) {            # (?:[\/]|\z) means this is a complete path segment
      substr($input, 0, 2, '/')
      # $substep = 'B';
    }
    #
    # C. if the input buffer begins with a prefix of "/../" or "/..",
    #    where ".." is a complete path segment, then replace that
    #    prefix with "/" in the input buffer and remove the last
    #    segment and its preceding "/" (if any) from the output
    #    buffer; otherwise,
    #
    elsif (index($input, '/../') == 0) {
      substr($input, 0, 4, '/'),
      $output =~ s/\/?[^\/]*\z//
      # $substep = 'C';
    }
    elsif ($input =~ /^\/\.\.(?:[\/]|\z)/) {          # (?:[\/]|\z) means this is a complete path segment
      substr($input, 0, 3, '/'),
      $output =~ s/\/?[^\/]*\z//
      # $substep = 'C';
    }
    #
    # D. if the input buffer consists only of "." or "..", then remove
    #    that from the input buffer; otherwise,
    #
    elsif (($input eq '.') || ($input eq '..')) {
      $input = ''
      # $substep = 'D';
    }
    #
    # E. move the first path segment in the input buffer to the end of
    #    the output buffer, including the initial "/" character (if
    #    any) and any subsequent characters up to, but not including,
    #    the next "/" character or the end of the input buffer.
    #
    #    Note: "or the end of the input buffer" ?
    #
    else {
      $input =~ /^\/?([^\/]*)/,                           # This will always match
      $output .= substr($input, $-[0], $+[0] - $-[0], '') # Note that perl has no problem when $+[0] == $-[0], it will simply do nothing
      # $substep = 'E';
    }
    # printf STDERR "%-10s %-30s %-30s\n", "$step$substep", $output, $input;
  }
  #
  # 3. Finally, the output buffer is returned as the result of
  #    remove_dot_segments.
  #
  $output
}

sub unescape {
  my ($class, $value, $unreserved) = @_;

  my $unescaped_ok = 1;
  my $unescaped;
  try {
    my $octets = '';
    while ($value =~ m/(?<=%)[^%]+/gp) {
      $octets .= chr(hex(${^MATCH}))
    }
    $unescaped = MarpaX::RFC::RFC3629->new($octets)->output
  } catch {
    $unescaped_ok = 0;
    return
  };
  #
  # Keep only characters in the unreserved set
  #
  if ($unescaped_ok) {
    my $new_value = '';
    my $position_in_original_value = 0;
    my $reescaped_ok = 1;
    foreach (split('', $unescaped)) {
      my $reencoded_length;
      try {
        my $character = $_;
        my $reencoded = join('', map { '%' . uc(unpack('H2', $_)) } split(//, encode('UTF-8', $character, Encode::FB_CROAK)));
        $reencoded_length = length($reencoded);
      } catch {
        $reescaped_ok = 0;
      };
      last if (! $reescaped_ok);
      if ($_ =~ $unreserved) {
        $new_value .= $_;
      } else {
        $new_value = substr($value, $position_in_original_value, $reencoded_length);
      }
      $position_in_original_value += $reencoded_length;
    }
    $value = $new_value if ($reescaped_ok);
  }
  $value
}

# =============================================================================
# Internal class methods
# =============================================================================
sub _generate_attributes {
  my $class = shift;
  my $type = shift;
  my ($indice_start, $indice_end) = (shift, shift);
  foreach (@_) {
    my $builder = "build_$_";
    has $_ => (is => 'ro', isa => HashRef[CodeRef],
               lazy => 1,
               builder => $builder,
               handles_via => 'Hash',
               handles => {
                           "get_$_"    => 'get',
                           "set_$_"    => 'set',
                           "exists_$_" => 'exists',
                           "delete_$_" => 'delete',
                           "kv_$_"     => 'kv',
                           "keys_$_"   => 'keys',
                           "values_$_" => 'values',
                          }
              );
  }
  my $_type_names   = "_${type}_names";
  my $_type_wrapper = "_${type}_wrapper";
  my @_type_names = ();
  push(@_type_names, undef) for (0..$indice_start - 1);
  push(@_type_names, @_);
  push(@_type_names, undef) for ($indice_end + 1..$MAX);
  has $_type_names   => (is => 'ro', isa => ArrayRef[Str|Undef], default => sub { \@_type_names });
  has $_type_wrapper => (is => 'ro', isa => ArrayRef[CodeRef|Undef], lazy => 1,
                         handles_via => 'Array',
                         handles => {
                                     "_get_$type" => 'get'
                                    },
                         builder => sub {
                           $_[0]->_build_impl_sub($indice_start, $indice_end, $_type_names)
                         }
                        );
}
# =============================================================================
# Internal instance methods
# =============================================================================
sub _build_impl_sub {
  my ($self, $istart, $iend, $names) = @_;
  my @array = ();
  foreach (0..$MAX) {
    if (($_ < $istart) || ($_ > $iend)) {
      push(@array, undef);
    } else {
      my $name = $self->$names->[$_];
      my $exists = "exists_$name";
      my $getter = "get_$name";
      #
      # We KNOW in advance that we are talking with a hash. So no need to
      # to do extra calls. The $exists and $getter variables are intended
      # for the outside world.
      # The inlined version using these accessors is:
      my $inlined_with_accessors = <<INLINED_WITH_ACCESSORS;
  # my (\$self, \$criteria, \$value) = \@_;
  #
  # At run-time, in particular Protocol-based normalizers,
  # the callbacks can be altered
  #
  \$_[0]->$exists(\$_[1]) ? goto \$_[0]->$getter(\$_[1]) : \$_[2]
INLINED_WITH_ACCESSORS
      # The inlined version using direct perl op is:
      my $inlined_without_accessors = <<INLINED_WITHOUT_ACCESSORS;
  # my (\$self, \$criteria, \$value) = \@_;
  #
  # At run-time, in particular Protocol-based normalizers,
  # the callbacks can be altered
  #
  exists(\$_[0]->{$name}->{\$_[1]}) ? goto \$_[0]->{$name}->{\$_[1]} : \$_[2]
INLINED_WITHOUT_ACCESSORS
      push(@array,eval "sub {$inlined_without_accessors}")
    }
  }
  \@array
}

BEGIN {
  #
  # Marpa internal optimisation: we do not want the closures to be rechecked every time
  # we call $r->value(). This is a static information, although determined at run-time
  # the first time $r->value() is called on a recognizer.
  #
  no warnings 'redefine';

  sub Marpa::R2::Recognizer::registrations {
    my $recce = shift;
    if (@_) {
      my $hash = shift;
      if (! defined($hash) ||
          ref($hash) ne 'HASH' ||
          grep {! exists($hash->{$_})} qw/
                                           NULL_VALUES
                                           REGISTRATIONS
                                           CLOSURE_BY_SYMBOL_ID
                                           CLOSURE_BY_RULE_ID
                                           RESOLVE_PACKAGE
                                           RESOLVE_PACKAGE_SOURCE
                                           PER_PARSE_CONSTRUCTOR
                                         /) {
        Marpa::R2::exception(
                             "Attempt to reuse registrations failed:\n",
                             "  Registration data is not a hash containing all necessary keys:\n",
                             "  Got : " . ((ref($hash) eq 'HASH') ? join(', ', sort keys %{$hash}) : '') . "\n",
                             "  Want: CLOSURE_BY_RULE_ID, CLOSURE_BY_SYMBOL_ID, NULL_VALUES, PER_PARSE_CONSTRUCTOR, REGISTRATIONS, RESOLVE_PACKAGE, RESOLVE_PACKAGE_SOURCE\n"
                            );
      }
      $recce->[Marpa::R2::Internal::Recognizer::NULL_VALUES] = $hash->{NULL_VALUES};
      $recce->[Marpa::R2::Internal::Recognizer::REGISTRATIONS] = $hash->{REGISTRATIONS};
      $recce->[Marpa::R2::Internal::Recognizer::CLOSURE_BY_SYMBOL_ID] = $hash->{CLOSURE_BY_SYMBOL_ID};
      $recce->[Marpa::R2::Internal::Recognizer::CLOSURE_BY_RULE_ID] = $hash->{CLOSURE_BY_RULE_ID};
      $recce->[Marpa::R2::Internal::Recognizer::RESOLVE_PACKAGE] = $hash->{RESOLVE_PACKAGE};
      $recce->[Marpa::R2::Internal::Recognizer::RESOLVE_PACKAGE_SOURCE] = $hash->{RESOLVE_PACKAGE_SOURCE};
      $recce->[Marpa::R2::Internal::Recognizer::PER_PARSE_CONSTRUCTOR] = $hash->{PER_PARSE_CONSTRUCTOR};
    }
    return {
            NULL_VALUES            => $recce->[Marpa::R2::Internal::Recognizer::NULL_VALUES],
            REGISTRATIONS          => $recce->[Marpa::R2::Internal::Recognizer::REGISTRATIONS],
            CLOSURE_BY_SYMBOL_ID   => $recce->[Marpa::R2::Internal::Recognizer::CLOSURE_BY_SYMBOL_ID],
            CLOSURE_BY_RULE_ID     => $recce->[Marpa::R2::Internal::Recognizer::CLOSURE_BY_RULE_ID],
            RESOLVE_PACKAGE        => $recce->[Marpa::R2::Internal::Recognizer::RESOLVE_PACKAGE],
            RESOLVE_PACKAGE_SOURCE => $recce->[Marpa::R2::Internal::Recognizer::RESOLVE_PACKAGE_SOURCE],
            PER_PARSE_CONSTRUCTOR  => $recce->[Marpa::R2::Internal::Recognizer::PER_PARSE_CONSTRUCTOR]
           };
  } ## end sub registrations

  sub Marpa::R2::Scanless::R::registrations {
    my $slr = shift;
    my $thick_g1_recce =
      $slr->[Marpa::R2::Internal::Scanless::R::THICK_G1_RECCE];
    return $thick_g1_recce->registrations(@_);
  } ## end sub Marpa::R2::Scanless::R::registrations

}

1;
