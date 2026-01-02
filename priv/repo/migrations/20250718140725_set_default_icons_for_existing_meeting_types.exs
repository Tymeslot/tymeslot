defmodule Tymeslot.Repo.Migrations.SetDefaultIconsForExistingMeetingTypes do
  use Ecto.Migration

  def change do
    # Set default icon to 'none' for existing meeting types that don't have an icon
    execute """
    UPDATE meeting_types 
    SET icon = 'none' 
    WHERE icon IS NULL;
    """
  end
end
