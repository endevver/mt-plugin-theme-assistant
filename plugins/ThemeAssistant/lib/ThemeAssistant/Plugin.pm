package ThemeAssistant::Plugin;

use strict;
use warnings;

use Data::Dumper;

# This callback is run after a theme is applied and willl do various things to
# make deploying themes easier.
sub callback_post_apply_theme {
    _install_custom_fields(@_);
    _set_module_caching_prefs(@_);
    _override_caching_settings(@_);
}

# Process all of the Custom Fields to be installed.
sub _install_custom_fields {
    my ($cb, $theme, $blog) = @_;
    return unless MT->component('Commercial');

    my $app = MT->instance;
    my $ta  = $app->component('ThemeAssistant');

    my $ts_id = $blog->template_set or return;
    my $set   = $app->registry( 'template_sets', $ts_id ) or return;

    # In order to refresh both the blog-level and system-level custom fields,
    # merge each of those hashes. We don't have to worry about those hashes
    # not having unique keys, because the keys are the custom field basenames
    # and custom field basenames must be unique regardless of whether they
    # are for the blog or system.
    my $fields = {};

    # Any fields under the "sys_fields" key should be created/updated
    # as should any key under the "fields" key. I'm not sure why/when both
    # of these types were created/introduced. It makes sense that maybe
    # "sys_fields" is for system custom fields and "fields" is for blog level
    # custom fields, however the scope key means that they can be used
    # interchangeably.
    @$fields{ keys %{ $set->{sys_fields} } } = values %{ $set->{sys_fields} };
    @$fields{ keys %{ $set->{fields} } }     = values %{ $set->{fields} };

    # Give up if there are no custom fields to install.
    return unless $fields;

    FIELD: while ( my ( $field_id, $field_data ) = each %$fields ) {
        next if UNIVERSAL::isa( $field_data, 'MT::Component' );    # plugin

        # Install the field.
        _install_custom_field({
            field_id   => $field_id,
            field_data => $field_data,
            blog       => $blog,
        });
    }
}

# Install the Custom Field
sub _install_custom_field {
    my ($arg_ref)  = @_;
    my $field_id   = $arg_ref->{field_id};
    my $field_data = $arg_ref->{field_data};
    my $blog       = $arg_ref->{blog};

    my %field = %$field_data;
    delete @field{qw( blog_id basename )};
    my $field_name  = delete $field{label} || $field{name};
    my $field_scope = ( $field{scope}
                    && delete $field{scope} eq 'system' ? 0 : $blog->id );
    $field_name = $field_name->() if 'CODE' eq ref $field_name;

    # If the custom field definition is missing the required basic field
    # definitions then we should report that problem immediately.
    REQUIRED: for my $required (qw( obj_type tag )) {
        next REQUIRED if $field{$required};

        die "Theme Assistant could not install custom field $field_id: field "
            . "attribute $required is required.";
    }

    # Does the blog have a field with this basename?
    my $field_obj = MT->model('field')->load({
        blog_id  => $field_scope,
        basename => $field_id,
        obj_type => $field_data->{obj_type} || q{},
    });

    if ($field_obj) {

        # The field data type can't just be changed willy-nilly. Because
        # different data types store data in different formats and in
        # different fields we can't expect to change to another field type
        # and just see things continue to work. So, disallow changing the field
        # type and report the problem immediately.
        if ( $field_obj->type ne $field_data->{type} ) {
            die "Theme Assistant could not install custom field $field_id on "
                . 'blog ' . $blog->name . ": the blog already has a field "
                . "$field_id with a conflicting type.";
        }
    }
    else {

        # This field doesn't exist yet.
        $field_obj = MT->model('field')->new;
    }

    # Finally, create (or update) the Custom Field.
    $field_obj->set_values({
        blog_id  => $field_scope,
        name     => $field_name,
        basename => $field_id,
        %field,
    });
    $field_obj->save()
        or die 'Theme Assistant ran into an error when saving the custom '
            . "field $field_name: ".$field_obj->errstr;
}

# Set Template Module and Widget caching and include options.
sub _set_module_caching_prefs {
    my ($cb, $theme, $blog) = @_;
    my $app = MT->instance;

    my $ts_id = $blog->template_set or return;
    my $set   = $app->registry( 'template_sets', $ts_id ) or return;
    my $tmpls = $app->registry( 'template_sets', $ts_id, 'templates' );

    foreach my $t (qw( module widget )) {
        # Give up if there are no templates that match
        next unless eval { %{ $tmpls->{$t} } };

        foreach my $m ( keys %{ $tmpls->{$t} } ) {
            if ( $tmpls->{$t}->{$m}->{cache} ) {
                my $tmpl = MT->model('template')->load({
                    blog_id    => $blog->id,
                    identifier => $m,
                });
                foreach ( qw( expire_type expire_interval expire_event ) ) {
                    my $var = 'cache_' . $_;
                    my $val = $tmpls->{$t}->{$m}->{cache}->{$_};
                    if ($val) {
                        $val = ( $val * 60 ) if ( $_ eq 'expire_interval' );
                        $tmpl->$var($val);
                    }
                }

                $tmpl->save
                    or die 'Error saving template caching options: '
                        . $tmpl->errstr;
            }
        }
    }
}

# Forcibly turn on module caching at the blog level, so that any theme cache
# options actually work. Note that this only enables caching, not Includes.
sub _override_caching_settings {
    my ($cb, $theme, $blog) = @_;
    $blog->include_cache(1);
    $blog->save
        or die 'Error saving blog: '.$blog->errstr;
}

1;

__END__
