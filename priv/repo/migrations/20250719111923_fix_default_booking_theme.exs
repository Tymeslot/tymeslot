defmodule Tymeslot.Repo.Migrations.FixDefaultBookingTheme do
  use Ecto.Migration

  def change do
    # Update all profiles with booking_theme "default" to use "1" (Quill theme)
    execute(
      "UPDATE profiles SET booking_theme = '1' WHERE booking_theme = 'default'",
      "UPDATE profiles SET booking_theme = 'default' WHERE booking_theme = '1'"
    )
  end
end
