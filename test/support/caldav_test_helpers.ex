defmodule Tymeslot.CalDAVTestHelpers do
  @moduledoc """
  Shared test helpers for CalDAV-based calendar providers.

  Provides common assertions for CalDAV, Nextcloud, and Radicale providers.
  """

  import ExUnit.Assertions

  @doc """
  Asserts that a schema has the required CalDAV base fields.
  """
  @spec assert_has_caldav_base_fields(map()) :: :ok
  def assert_has_caldav_base_fields(schema) do
    assert schema[:base_url][:type] == :string
    assert schema[:base_url][:required] == true
    assert schema[:username][:type] == :string
    assert schema[:username][:required] == true
    assert schema[:password][:type] == :string
    assert schema[:password][:required] == true

    :ok
  end
end
