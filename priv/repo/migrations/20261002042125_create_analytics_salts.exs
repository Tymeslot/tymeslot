defmodule Tymeslot.Repo.Migrations.CreateAnalyticsSalts do
  @moduledoc """
  One random salt per UTC day for the cookie-less analytics visitor hash.

  The salt used to be derived from the date and a fixed secret, so any past
  day's salt could be rebuilt from that secret, and a stored hash brute-forced
  back to the visitor's IP address. A random salt, shared by every node through
  this table and deleted once its day is over, cannot be rebuilt.

  The table starts empty: the first hash of each day creates that day's row.
  """
  use Ecto.Migration

  def change do
    create table(:analytics_salts, primary_key: false) do
      add(:date, :date, primary_key: true)
      add(:salt, :binary, null: false)
    end
  end
end
