package PgToolkit::Compactor::Database;

use base qw(PgToolkit::Compactor);

use strict;
use warnings;

=head1 NAME

B<PgToolkit::Compactor::Database> - a database level processing for bloat
reducing.

=head1 SYNOPSIS

	my $database_compactor = PgToolkit::Compactor::Database->new(
		database => $database,
		logger => $logger,
		schema_compactor_constructor => $schema_compactor_constructor,
		schema_name_list => ['schema1', 'schema2'],
		excluded_schema_name_list => [],
		no_pgstatuple => 0);

	$database_compactor->process();

=head1 DESCRIPTION

B<PgToolkit::Compactor::Database> class is an implementation of a database
level processing logic for bloat reducing mechanism.

=head3 Constructor arguments

=over 4

=item C<database>

a database object

=item C<logger>

a logger object

=item C<schema_compactor_constructor>

a schema compactor constructor code reference

=item C<schema_name_list>

a list of schema names to process

=item C<excluded_schema_name_list>

a list of schema names to exclude from processing

=item C<no_pgstatuple>

do not use pgstattuple to calculate statictics.

=back

=cut

sub _init {
	my ($self, %arg_hash) = @_;

	$self->{'_database'} = $arg_hash{'database'};

	$self->{'_ident'} = $self->{'_database'}->quote_ident(
		string => $self->{'_database'}->get_dbname());

	$self->{'_log_target'} = $self->{'_ident'};

	$self->{'_logger'}->write(
		message => 'Creating environment.',
		level => 'info',
		target => $self->{'_log_target'});
	$self->_create_clean_pages_function();

	my %schema_name_hash = map(
		($_ => 1), @{$arg_hash{'schema_name_list'}} ?
		@{$arg_hash{'schema_name_list'}} : @{$self->_get_schema_name_list()});

	delete @schema_name_hash{@{$arg_hash{'excluded_schema_name_list'}}};

	my $pgstattuple_schema_name;
	if (not $arg_hash{'no_pgstatuple'}) {
		$pgstattuple_schema_name = $self->_get_pgstattuple_schema_name();
	}

	if ($pgstattuple_schema_name) {
		$self->{'_logger'}->write(
			message => 'Statictics calculation method: pgstattuple.',
			level => 'info',
			target => $self->{'_log_target'});
	} else {
		$self->{'_logger'}->write(
			message => 'Statictics calculation method: approximation.',
			level => 'notice',
			target => $self->{'_log_target'});
	}

	$self->{'_schema_compactor_list'} = [];
	for my $schema_name (sort keys %schema_name_hash) {
		my $schema_compactor = $arg_hash{'schema_compactor_constructor'}->(
			database => $self->{'_database'},
			schema_name => $schema_name,
			pgstattuple_schema_name => $pgstattuple_schema_name);
		push(@{$self->{'_schema_compactor_list'}}, $schema_compactor);
	}

	return;
}

sub _process {
	my $self = shift;

	for my $schema_compactor (@{$self->{'_schema_compactor_list'}}) {
		if (not $schema_compactor->is_processed()) {
			$schema_compactor->process();
		}
	}

	if ($self->is_processed()) {
		$self->{'_logger'}->write(
			message => 'Processing complete.',
			level => 'info',
			target => $self->{'_log_target'});
	} else {
		$self->{'_logger'}->write(
			message => ('Processing incomplete: '.$self->_incomplete_count().
						' schemas left.'),
			level => 'warning',
			target => $self->{'_log_target'});
	}

	return;
}

=head1 METHODS

=head2 B<is_processed()>

Tests if the database is processed.

=head3 Returns

True or false value.

=cut

sub is_processed {
	my $self = shift;

	my $result = 1;
	map(($result &&= $_->is_processed()), @{$self->{'_schema_compactor_list'}});

	return $result;
}

sub DESTROY {
	my $self = shift;

	$self->_drop_clean_pages_function();
	$self->{'_logger'}->write(
		message => 'Dropping environment.',
		level => 'info',
		target => $self->{'_log_target'});
}

sub _incomplete_count {
	my $self = shift;

	my $result = 0;
	map(($result += not $_->is_processed()),
		@{$self->{'_schema_compactor_list'}});

	return $result;
}

sub _get_pgstattuple_schema_name {
	my $self = shift;

	my $result = $self->{'_database'}->execute(
			sql => <<SQL
SELECT nspname FROM pg_catalog.pg_proc
JOIN pg_catalog.pg_namespace AS n ON pronamespace = n.oid
WHERE proname = 'pgstattuple' LIMIT 1
SQL
		);

	return @{$result} ? $result->[0]->[0] : undef;
}

sub _get_schema_name_list {
	my $self = shift;

	my $result = $self->{'_database'}->execute(
			sql => <<SQL
SELECT nspname FROM pg_catalog.pg_namespace
WHERE nspname NOT IN ('pg_catalog', 'information_schema') AND nspname !~ 'pg_.*'
ORDER BY 1
SQL
		);

	return [map($_->[0], @{$result})];
}

sub _create_clean_pages_function {
	my $self = shift;

	$self->{'_database'}->execute(
		sql => << 'SQL'
CREATE OR REPLACE FUNCTION public._clean_pages(
    i_table_ident text,
    i_column_ident text,
    i_to_page integer,
    i_page_offset integer,
    i_max_tupples_per_page integer)
RETURNS integer
LANGUAGE plpgsql AS $$
DECLARE
    _from_page integer := i_to_page - i_page_offset + 1;
    _min_ctid tid;
    _max_ctid tid;
    _ctid_list tid[];
    _next_ctid_list tid[];
    _ctid tid;
    _loop integer;
    _result_page integer;
    _update_query text :=
        'UPDATE ONLY ' || i_table_ident ||
        ' SET ' || i_column_ident || ' = ' || i_column_ident ||
        ' WHERE ctid = ANY($1) RETURNING ctid';
BEGIN
    -- Check page argument values
    IF NOT (
        i_page_offset IS NOT NULL OR i_page_offset > 1 OR
        i_to_page IS NOT NULL OR i_to_page > 1 OR
        i_to_page > i_page_offset)
    THEN
        RAISE EXCEPTION 'Wrong page arguments specified.';
    END IF;

    -- Prevent triggers firing on update
    SET LOCAL session_replication_role TO replica;

    -- Define minimal and maximal ctid values of the range
    _min_ctid := (_from_page, 1)::text::tid;
    _max_ctid := (i_to_page, i_max_tupples_per_page)::text::tid;

    -- Build a list of possible ctid values of the range
    SELECT array_agg((pi, ti)::text::tid)
    INTO _ctid_list
    FROM generate_series(_from_page, i_to_page) AS pi
    CROSS JOIN generate_series(1, i_max_tupples_per_page) AS ti;

    <<_outer_loop>>
    FOR _loop IN 1..i_max_tupples_per_page LOOP
        _next_ctid_list := array[]::tid[];

        -- Update all the tuples in the range
        FOR _ctid IN EXECUTE _update_query USING _ctid_list
        LOOP
            IF _ctid > _max_ctid THEN
                RAISE EXCEPTION 'No more free space left in the table.';
            ELSIF _ctid >= _min_ctid THEN
                -- The tuple is still in the range, more updates are needed
                _next_ctid_list := _next_ctid_list || _ctid;
            END IF;
        END LOOP;

        _ctid_list := _next_ctid_list;

        -- Finish processing if there are no tupples in the range left
        IF coalesce(array_length(_ctid_list, 1), 0) = 0 THEN
            _result_page := _from_page - 1;
            EXIT _outer_loop;
        END IF;
    END LOOP;

    -- No result
    IF _loop = i_max_tupples_per_page AND _result_page IS NULL THEN
        RAISE EXCEPTION
            'Maximal loops count has been reached with no result.';
    END IF;

    RETURN _result_page;
END $$;
SQL
		);

	return;
}

sub _drop_clean_pages_function {
	my $self = shift;

	$self->{'_database'}->execute(
		sql => <<SQL
DROP FUNCTION public._clean_pages(text, text, integer, integer, integer);
SQL
		);

	return;
}

=head1 SEE ALSO

=over 4

=item L<PgToolkit::Class>

=back

=head1 LICENSE AND COPYRIGHT

Copyright 2010-2011 postgresql-consulting.com

TODO Licence boilerplate

=head1 AUTHOR

=over 4

=item L<Sergey Konoplev|mailto:sergey.konoplev@postgresql-consulting.com>

=back

=cut

1;
