defmodule Tymeslot.Repo.Migrations.FixLocalVideoProvider do
  use Ecto.Migration

  def up do
    execute """
    UPDATE video_integrations 
    SET provider = 'none' 
    WHERE provider = 'local'
    """
  end

  def down do
    # We don't want to revert this fix
    :ok
  end
end