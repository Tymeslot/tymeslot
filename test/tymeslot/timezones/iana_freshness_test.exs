defmodule Tymeslot.Timezones.IanaFreshnessTest do
  @moduledoc """
  Guards the vendored IANA time zone database against upstream releases.

  The tz data is pinned (`config :tz, :iana_version`) and shipped in
  `priv/tz`, and no running instance checks for newer releases: an update
  reaches users only through a Tymeslot release. IANA publishes rule changes
  at a few weeks' notice, and a missed one puts booking slots an hour out in
  the affected zones. Excluded from default runs because it needs the
  network; the nightly `Excluded suites` workflow is what makes it bite.
  """

  use ExUnit.Case, async: true

  @moduletag :utils
  @moduletag :tz_freshness

  @version_url "https://data.iana.org/time-zones/tzdb/version"

  test "the vendored time zone database is IANA's latest release" do
    pinned = Application.fetch_env!(:tz, :iana_version)
    upstream = @version_url |> Req.get!(retry: :transient) |> Map.fetch!(:body) |> String.trim()

    # Release names are a year and a letter (2026c), so they order as strings.
    assert upstream <= pinned,
           "IANA has published tzdata #{upstream}; this build vendors #{pinned}. Run: " <>
             "mix tz.download #{upstream} && mix deps.compile tz --force, " <>
             "then set config :tz, :iana_version to #{inspect(upstream)}"
  end
end
