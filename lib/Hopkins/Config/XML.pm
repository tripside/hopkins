package Hopkins::Config::XML;

use strict;
use warnings;

=head1 NAME

Hopkins::Config::XML - hopkins configuration via XML

=head1 DESCRIPTION

Hopkins::Config encapsulates all of the busywork associated
in the reading and post-processing of the XML configuration
in addition to providing a simple interface to accessing
values when required.

=cut

use DateTime;
use DateTime::Event::MultiCron;
use DateTime::Set;
use File::Monitor;
use Path::Class::Dir;
use XML::Simple;
use YAML;

use Hopkins::Config::Status;
use Hopkins::Task;

use Class::Accessor::Fast;

use base qw(Class::Accessor::Fast Hopkins::Config);

__PACKAGE__->mk_accessors(qw(config file monitor));

=head1 METHODS

=over 4

=item new

=cut

sub new
{
	my $self = shift->SUPER::new(@_);

	$self->monitor(new File::Monitor);
	$self->monitor->watch($self->file);

	return $self;
}

=item load

=cut

sub load
{
	my $self = shift;

	Hopkins->log_debug('loading XML configuration file');

	my $status = new Hopkins::Config::Status;
	my $config = $self->parse($self->file, $status);

	# if we have an existing configuration, then we will be
	# fine.  we won't overwrite the existing configuration
	# with a broken one, so no error condition will exist.

	$status->ok($self->config ? 1 : 0);

	if (not defined $config) {
		$status->failed(1);
		$status->parsed(0);

		Hopkins->log_error('failed to load XML configuration file: ' . $status->errmsg);

		return $status;
	}

	$status->parsed(1);

	if (my $root = $config->{state}->{root}) {
		$config->{state}->{root} = new Path::Class::Dir $root;
		eval { $config->{state}->{root}->mkpath(0, 0700) };
		if (my $err = $@) {
			Hopkins->log_error("unable to create $root: $@");
			$status->failed(1);
		}
	} else {
		Hopkins->log_error('no root directory defined for state information');
		$status->failed(1)
	}

	# process task configuration data structure.  each task
	# definition is inflated into a Hopkins::Task instance.
	# schedules are inflated into DateTime::Set objects via
	# DateTime::Event::MultiCron.  other forms of schedule
	# definitions may be supported in the future, so long as
	# they grok DateTime::Set.

	foreach my $name (keys %{ $config->{task} }) {
		my $href = $config->{task}->{$name};

		# collapse the damn task queue from the ForceArray
		# and interpret the value of the enabled attribute

		$href->{queue}		= $href->{queue}->[0] if ref $href->{queue};
		$href->{enabled}	= lc($href->{enabled}) eq 'no' ? 0 : 1;

		my $task = new Hopkins::Task { name => $name, %$href };

		if (not $task->queue) {
			Hopkins->log_error("task $name not assigned to a queue");
			$status->failed(1);
		}

		if (not $task->class || $task->cmd) {
			Hopkins->log_error("task $name lacks a class or command line");
			$status->failed(1);
		}

		if ($task->class and $task->cmd) {
			Hopkins->log_error("task $name using mutually exclusive class/cmd");
			$status->failed(1);
		}

		$task->schedule($self->_setup_schedule($status, $task));

		$config->{task}->{$name} = $task;
	}

	$self->_setup_chains($config, $status, values %{ $config->{task} });

	# check to see if the new configuration includes a
	# modified database configuration.

	if (my $href = $self->config && $self->config->{database}) {
		my @a = map { $href->{$_} || '' } qw(dsn user pass options);
		my @b = map { $config->{database}->{$_} } qw(dsn user pass options);

		# replace the options hashref (very last element in
		# the array) with a flattened representation

		splice @a, -1, 1, keys %{ $a[-1] }, values %{ $a[-1] };
		splice @b, -1, 1, keys %{ $b[-1] }, values %{ $b[-1] };

		# temporarily change the list separator character
		# (default 0x20, a space) to the subscript separator
		# character (default 0x1C) for a precise comparison
		# of the two configurations

		local $" = $;;

		$status->store_modified("@a" ne "@b");
	}

	if (not $status->failed) {
		$self->config($config);
		$status->updated(1);
		$status->ok(1);
	}

	return $status;
}

sub _setup_chains
{
	my $self	= shift;
	my $config	= shift;
	my $status	= shift;

	while (my $task = shift) {
		my @chain;

		next if not defined $task->chain;

		foreach my $href (@{ $task->chain }) {
			my $name = $href->{task};
			my $next = $config->{task}->{$name};

			if (not defined $next) {
				Hopkins->log_error("chained task $name for " . $task->name . " not found");
				$status->failed(1);
			}

			my $task = new Hopkins::Task $next;

			$task->options($href->{options});
			$task->chain($href->{chain});
			$task->schedule(undef);

			push @chain, $task;
		}

		$self->_setup_chains($config, $status, @chain);

		$task->chain(\@chain);
	}
}

sub _setup_schedule
{
	my $self	= shift;
	my $status	= shift;
	my $task	= shift;
	my $ref		= $task->{schedule};

	return undef if not defined $ref;

	my $superset = DateTime::Set->empty_set;

	if (my $aref = $ref->{cron}) {
		my $set = eval { DateTime::Event::MultiCron->from_multicron(@$aref) };

		if (my $err = $@) {
			Hopkins->log_error('unable to setup schedule for ' . $task->name . ': ' . $err);
			$status->failed(1);
			$status->errmsg($err);
		} else {
			$superset = $superset->union($set);
		}
	}

	return $superset;
}

sub parse
{
	my $self	= shift;
	my $file	= shift;
	my $status	= shift;

	my %xmlsopts =
	(
		ValueAttr		=> [ 'value' ],
		GroupTags		=> { options => 'option' },
		SuppressEmpty	=> '',
		ForceArray		=> [ 'plugin', 'task', 'chain', 'option', 'cron' ],
		ContentKey		=> '-value',
		ValueAttr		=> { option => 'value' },
		KeyAttr			=>
		{
			plugin	=> 'name',
			option	=> 'name',
			queue	=> 'name',
			task	=> 'name'
		}
	);

	my $xs	= new XML::Simple %xmlsopts;
	my $ref	= eval { $xs->XMLin($file) };

	if (my $err = $@) {
		$status->errmsg($err);

		return undef;
	}

	Hopkins->log_debug(Dump $ref);

	return $ref;
}

sub scan
{
	my $self = shift;

	return scalar $self->monitor->scan;
}

sub get_queue_names
{
	my $self	= shift;
	my $config	= $self->config || {};

	return $config->{queue} ? keys %{ $config->{queue} } : ();
}

sub get_task_names
{
	my $self	= shift;
	my $config	= $self->config || {};

	return $config->{task} ? keys %{ $config->{task} } : ();
}

sub get_task_info
{
	my $self = shift;
	my $task = shift;

	return $self->config->{task}->{$task};
}

sub get_queue_info
{
	my $self = shift;
	my $name = shift;

	return { name => $name, %{ $self->config->{queue}->{$name} } };
}

sub get_plugin_names
{
	my $self = shift;

	return keys %{ $self->config->{plugin} };
}

sub get_plugin_info
{
	my $self = shift;
	my $name = shift;

	return $self->config->{plugin}->{$name};
}

sub has_plugin
{
	my $self = shift;
	my $name = shift;

	return exists $self->config->{plugin}->{$name} ? 1 : 0;
}

sub fetch
{
	my $self = shift;
	my $path = shift;

	$path =~ s/^\/+//;

	my $ref = $self->config;

	foreach my $spec (split '/', $path) {
		for (ref($ref)) {
			/ARRAY/	and do { $ref = $ref->[$spec] }, next;
			/HASH/	and do { $ref = $ref->{$spec} }, next;

			$ref = undef;
		}
	}

	return $ref;
}

sub loaded
{
	my $self = shift;

	return $self->config ? 1 : 0;
}

=back

=head1 AUTHOR

Mike Eldridge <diz@cpan.org>

=head1 LICENSE

=cut

1;