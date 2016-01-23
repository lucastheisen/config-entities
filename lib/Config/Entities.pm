use strict;
use warnings;

package Config::Entities;

# ABSTRACT: An multi-level overridable perl based configuration module
# PODNAME: Config::Entities

use Cwd qw(abs_path);
use Data::Dumper;
use File::Find;
use File::Spec;
use Log::Any;

my $logger = Log::Any->get_logger();

our $properties = {};

sub new {
    my ($class, @args) = @_;
    return bless( {}, $class )->_init( @args );
}

sub fill {
    my ($self, $coordinate, $hashref, %options) = @_;
    
    my @entity = $self->get_entity( $coordinate, %options );
    foreach my $key ( keys( %$hashref ) ) {
        if ( ref( $entity[0] ) eq 'HASH' && defined( $entity[0]->{$key} ) ) {
            $hashref->{$key} = $entity[0]->{$key};
        }
        elsif ( $options{ancestry} ) {
            for ( my $index = 1; $index < scalar( @entity ); $index++ ) {
                if ( defined( $entity[$index]->{$key} ) ) {
                    $hashref->{$key} = $entity[$index]->{$key};
                    last;
                }
            }
        }
    }
    
    return $hashref;
}

sub get_entity {
    my ($self, $coordinate, %options) = @_;
    
    my @result = ($self);
    foreach my $coordinate_part ( split( /\./, $coordinate ) ) {
        my $child = $result[0]->{$coordinate_part};
        return if ( ! $child );
        unshift( @result, $child );
    }
    return $options{ancestry} ? @result : shift( @result );
}

sub _init {
    my ($self, @args) = @_;

    # if last arg is a hash, it is an options hash
    my $options = ref( $args[$#args] ) eq 'HASH'
        ? pop( @args )
        : {};

    # all other args are entities roots
    my @entities_roots = @args;

    if ( $options->{properties_file} ) {
        # merge in properties from a file
        $properties = do( $options->{properties_file} );
    }
    if ( $options->{properties} ) {
        # merge in direct properties
        foreach my $key ( keys( %{$options->{properties}} ) ) {
            $properties->{$key} = $options->{properties}{$key};
        }
    }

    if ( $options->{entity} ) {
        foreach my $key ( keys( %{$options->{entity}} ) ) {
            _merge( $self, $key, $options->{entity}{$key} );
        }
    }
    
    if ( scalar( @entities_roots ) ) {
        find( 
            sub { 
                if ( $_ =~ /^(.*)\.pmc?$/ && -f $File::Find::name ) {
                    my $key = $1;
    
                    my $hashref = $self;
                    my @directories = File::Spec->splitdir( 
                        substr( $File::Find::dir, length( $File::Find::topdir ) ) );
                    if ( scalar ( @directories ) ) {
                        shift( @directories ) while ( !$directories[0] );
                        foreach my $dir ( @directories ) {
                            if ( ! defined( $hashref->{$dir} ) ) {
                                $hashref->{$dir} = {};
                            }
                            $hashref = $hashref->{$dir};
                        }
                    }
                    
                    my $entity = do( $File::Find::name );
                    $logger->warn( 'unable to compile ', $File::Find::name, ': ', $@, "\n" )
                        if ( $@ );
                    _merge( $hashref, $key, $entity );
                }
            }, 
            map { Cwd::abs_path( $_ ) } @entities_roots );
    }

    _inherit( undef, $self );

    return $self;
}

sub _inherit {
    my ($parent, $child) = @_;
    if ( $child && (ref( $child ) eq 'HASH' || ref( $child ) eq 'Config::Entities') ) {
        if ( $parent && $child->{'Config::Entities::inherit'} ) {
            my $inherit = delete( $child->{'Config::Entities::inherit'} );
            if ( $inherit ) {
                foreach my $key ( @$inherit ) {
                    if ( defined( $parent->{$key} ) ) {
                        $child->{$key} = $parent->{$key} unless ( defined( $child->{$key} ) );
                    }
                }
            }
        }
        _inherit( $child, $child->{$_} ) foreach keys( %$child );
    }
}

sub _merge {
    my ($hashref, $key, $value) = @_;

    if ( ref( $value ) eq 'HASH' ) {
        # transfer key/value pairs from hashref
        # will merge rather than replace...
        if ( ! defined( $hashref->{$key} ) ) {
            $hashref->{$key} = {};
        }
        $hashref = $hashref->{$key};
    
        while ( my ($sub_key, $sub_value) = each( %$value ) ) {
            _merge( $hashref, $sub_key, $sub_value );
        }
    }
    else {
        # anything not a hashref will replace
        $hashref->{$key} = $value;
    }
}

1;

__END__
=head1 SYNOPSIS

    use Config::Entities;

    # Assuming this directory structure:
    #
    # /project/config/entities
    # |_______________________/a
    # |_________________________/b.pm
    # | { e => 'f' }
    # |
    # |_______________________/c.pm
    # | { g => 'h' }
    # |
    # |_______________________/c
    # |_________________________/d.pm
    # | { i => 'j' };
    my $entities = Config::Entities->new( '/project/config/entities' );
    my $abe = $entities->{a}{b}{e};    # 'f'
    my $ab = $entities->{a}{b};        # '{e=>'f'}
    my $ab_e = $ab->{e};               # 'f'
    my $cg = $entities->{c}{g};        # 'h'
    my $cd = $entities->{c}{d};        # {i=>'j'}
    my $cdi = $entities->{c}{d}{i};    # 'j'
    my $c = $entities->{c};            # {g=>'h',d=>{i=>'j'}}

    # Entities can be constructed with a set of properties to be used by configs.
    # Assuming this directory structure:
    #
    # /project/config/entities
    # |_______________________/a.pm
    # | { 
    # |     file => $Config::Entities::properties->{base_folder}
    # |         . '/sub/folder/file.txt'
    # | }
    my $entities = Config::Entities->new( '/project/config/entities',
        { properties => { base_folder => '/project' } } );
    my $file = $entities->{a}{file}; # /project/sub/folder/file.txt

    # You can also supply multiple entities folders
    # Assuming this directory structure:
    #
    # /project/config
    # |______________/entities
    # |_______________________/a.pm
    # | { b => 'c' } 
    # |
    # |______________/more_entities
    # |____________________________/d.pm
    # | { e => $Config::Entities::properties->{f} } 
    my $entities = Config::Entities->new( 
        '/project/config/entities',
        '/project/config/more_entities',
        { properties => {f => 'g'} } );     # { b => 'c', e => 'g' }
    
    # You can also specify a properties file  
    # Assuming this directory structure:
    #
    # /project/config
    # |______________/entities
    # |_______________________/a.pm
    # | { b => $Config::Entities::properties->{e} } 
    # |
    # |______________/properties.pl
    # | { e => 'f' } 
    my $entities = Config::Entities->new( 
        '/project/config/entities',
        { properties_file => '/project/config/properties.pl } );
    my $ab = $entities->{a}{b}; # 'f'
    
    # Assuming:
    #
    # {
    #     a => {
    #         b => {
    #             c => 'd',
    #             e => 'f'
    #         },
    #         g => 'h'
    #     }       
    # }
    #
    # You can use dotted notation to refer to entities using get_entity
    my $ab = $entities->get_entity( 'a.b' );    # {c=>'d',e=>'f'}
    # You can fill a hash with many values at once using fill
    my $ab_abc_abe = $entities->fill( 'a.b', 
        {c=>undef, e=>undef} );                 # {c=>'d',e=>'f'}
    # Perhaps the most useful approach is filling a hash from a coordinate
    # or its parents
    my $ab_abc_abe_ag = $entities->fill( 'a.b',
        {c=>undef, e=>undef, g=>undef}, 
        ancestry => 1 );                        # {c=>'d',e=>'f',g=>'h'}

=head1 DESCRIPTION

In essense, this module will recurse a directory structure, running C<do FILE>
for each entry and merging its results into the Entities object which can be
treated as a hash.  Given that it runs C<do FILE>, each config node is a fully
capable perl script.

=constructor new( $entities_root_dir [, $entities_root_dir, ...] \%options )

Recurses into each C<$entities_root_dir> loading its contents into the entities
map.  The filesystem structure will be propagated to the map, each sub folder
representing a sub hash.  If both C<Xxx.pm> and a folder C<Xxx> are found, the
C<Xxx.pm> will be loaded first then the recursion will enter C<Xxx> and merge 
its results over the top of what is already in the map.  If properties are
provided via C<properties> or C<properties_file>, they can be accessed using
C<Config::Entities::properties> in the individual config files.  The currently 
available options are:

=over 4

=item entity

A hashref containing configuration.  Will be overriden by the contents of any
C<$entities_root_dir>'s that are passed in.

=item properties

Properties to be loaded into C<Config::Entities::properties>.  Will override any
properties with the same name loaded by properties_file.

=item properties_file

A file that will be loaded into C<Config::Entities::properties> using C<do FILE>

=back

=method fill( $coordinate, $hashref, [%options] )

Will iterate through the keys of C<$hashref> setting the associated value to the
value found at the same key in the entity matching C<$coordinate>.  The 
currently available options are:

=over 4

=item ancestry

If true, the search will continue up the ancestry until it finds a match.

=back

=method get_entity( $coordinate, [%options] )

A simple dotted notation for indexing into the map.  For example, 
C<$entities->get_entity( 'a.b.c' )> is equivalent to 
C<$entities->{a}{b}{c}.  The currently available options are:

=over 4

=item ancestry

If true, a list will be returned where the first element is the matching entity, 
and each successive entity is its parent, all the way up to C<$self>.

=back
