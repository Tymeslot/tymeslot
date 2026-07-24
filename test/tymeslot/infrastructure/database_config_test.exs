defmodule Tymeslot.Infrastructure.DatabaseConfigTest do
  use ExUnit.Case, async: true
  @moduletag :infrastructure

  alias Tymeslot.Infrastructure.DatabaseConfig

  describe "build/2 for docker" do
    test "falls back to embedded-database defaults" do
      config = DatabaseConfig.build("docker", %{"POSTGRES_PASSWORD" => "secret"})

      assert config[:hostname] == "localhost"
      assert config[:port] == 5432
      assert config[:database] == "tymeslot"
      assert config[:username] == "tymeslot"
      assert config[:password] == "secret"
      assert config[:pool_size] == 60
      refute Keyword.has_key?(config, :url)
      refute Keyword.has_key?(config, :ssl)
    end

    test "reads the discrete external-database variables" do
      config =
        DatabaseConfig.build("docker", %{
          "DATABASE_HOST" => "db.internal",
          "DATABASE_PORT" => "6432",
          "POSTGRES_DB" => "bookings",
          "POSTGRES_USER" => "app",
          "POSTGRES_PASSWORD" => "secret",
          "DATABASE_POOL_SIZE" => "25"
        })

      assert config[:hostname] == "db.internal"
      assert config[:port] == 6432
      assert config[:database] == "bookings"
      assert config[:username] == "app"
      assert config[:pool_size] == 25
    end

    test "carries the shared connection tuning" do
      config = DatabaseConfig.build("docker", %{"POSTGRES_PASSWORD" => "secret"})

      assert config[:idle_interval] == 60_000
      assert config[:queue_target] == 5000
      assert config[:queue_interval] == 10_000
    end

    test "raises a helpful error when no password is configured" do
      assert_raise RuntimeError, ~r/POSTGRES_PASSWORD/, fn ->
        DatabaseConfig.build("docker", %{})
      end
    end

    test "raises on a non-integer port" do
      assert_raise RuntimeError, ~r/DATABASE_PORT/, fn ->
        DatabaseConfig.build("docker", %{"POSTGRES_PASSWORD" => "s", "DATABASE_PORT" => "abc"})
      end
    end
  end

  describe "build/2 for cloudron" do
    test "reads the Cloudron-provided variables" do
      config =
        DatabaseConfig.build("cloudron", %{
          "CLOUDRON_POSTGRESQL_URL" => "postgres://u:p@pg:5432/db",
          "CLOUDRON_POSTGRESQL_USERNAME" => "u",
          "CLOUDRON_POSTGRESQL_PASSWORD" => "p",
          "CLOUDRON_POSTGRESQL_HOST" => "pg",
          "CLOUDRON_POSTGRESQL_PORT" => "5432",
          "CLOUDRON_POSTGRESQL_DATABASE" => "db"
        })

      assert config[:url] == "postgres://u:p@pg:5432/db"
      assert config[:hostname] == "pg"
      assert config[:username] == "u"
      assert config[:password] == "p"
      assert config[:database] == "db"
      assert config[:pool_size] == 60
    end

    # Documents existing behaviour, not an endorsement: the Cloudron port is
    # passed through as a string. It is harmless because CLOUDRON_POSTGRESQL_URL
    # overrides it — Ecto merges URL-derived options over the rest. Changing it
    # is a separate decision from this refactor.
    test "passes the Cloudron port through unparsed" do
      config = DatabaseConfig.build("cloudron", %{"CLOUDRON_POSTGRESQL_PORT" => "5432"})

      assert config[:port] == "5432"
    end
  end
end
