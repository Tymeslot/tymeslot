defmodule Tymeslot.Repo.Migrations.UpdateMeetingTypeIcons do
  use Ecto.Migration

  def up do
    # Update any existing meeting types that use the old icon names
    execute """
    UPDATE meeting_types 
    SET icon = 'hero-flag' 
    WHERE icon = 'hero-target';
    """

    execute """
    UPDATE meeting_types 
    SET icon = 'hero-beaker' 
    WHERE icon = 'hero-cup';
    """
  end

  def down do
    # Revert back to old icon names if rolling back
    execute """
    UPDATE meeting_types 
    SET icon = 'hero-target' 
    WHERE icon = 'hero-flag';
    """

    execute """
    UPDATE meeting_types 
    SET icon = 'hero-cup' 
    WHERE icon = 'hero-beaker';
    """
  end
end