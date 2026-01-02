defmodule Tymeslot.Repo do
  use Ecto.Repo,
    otp_app: :tymeslot,
    adapter: Ecto.Adapters.Postgres
end
