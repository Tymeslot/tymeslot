defmodule Tymeslot.Repo.Migrations.CreateDefaultAvailabilityForExistingUsers do
  use Ecto.Migration

  def up do
    # Create default availability for all existing profiles
    execute """
    INSERT INTO weekly_availability (profile_id, day_of_week, is_available, start_time, end_time, inserted_at, updated_at)
    SELECT 
      p.id as profile_id,
      days.day_of_week,
      CASE WHEN days.day_of_week BETWEEN 1 AND 5 THEN true ELSE false END as is_available,
      CASE WHEN days.day_of_week BETWEEN 1 AND 5 THEN '11:00:00'::time ELSE NULL END as start_time,
      CASE WHEN days.day_of_week BETWEEN 1 AND 5 THEN '19:30:00'::time ELSE NULL END as end_time,
      NOW() as inserted_at,
      NOW() as updated_at
    FROM profiles p
    CROSS JOIN (SELECT generate_series(1, 7) as day_of_week) days
    WHERE NOT EXISTS (
      SELECT 1 FROM weekly_availability wa WHERE wa.profile_id = p.id
    );
    """
  end

  def down do
    # Remove all weekly availability records
    execute "DELETE FROM weekly_availability;"
  end
end