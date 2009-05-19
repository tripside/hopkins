package Hopkins::Task;

use strict;

=head1 NAME

Hopkins::Task - task object

=head1 DESCRIPTION

Hopkins::Task represents a configured task that is available
for enqueuing.  it typically has a schedule associated with
it.

=cut

use Class::Accessor::Fast;

use base 'Class::Accessor::Fast';

__PACKAGE__->mk_accessors(qw(name class cmd queue schedule options chain run enabled onerror));

=back

=head1 AUTHOR

Mike Eldridge <diz@cpan.org>

=head1 LICENSE

=cut

1;
