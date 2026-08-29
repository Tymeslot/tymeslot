defmodule Mix.Tasks.Tymeslot.SyncTlds do
  @moduledoc """
  Regenerates the delegated TLD list in `priv/tlds.json` from IANA.

  `Tymeslot.Security.FieldValidators.TLDList` rejects any domain ending absent
  from that file, so the file being current is what stands between a real
  address and a refused booking. It was hand-maintained for its first three
  years and drifted badly in both directions: by 2026-08 it was missing six
  delegated TLDs (`.homes` among them, which cost a self-hosted user their
  bookings) while carrying 98 endings ICANN has never delegated or has since
  retired. This task replaces that maintenance with a fetch.

  **Run it before cutting a release.** A release freezes the snapshot for every
  self-hosted instance until that instance upgrades, so release time is the only
  moment the list can be refreshed for the people running it.

  ## Usage

      mix tymeslot.sync_tlds           # rewrite priv/tlds.json, print the diff
      mix tymeslot.sync_tlds --check   # report drift and exit 1, changing nothing

  Requires network access to https://data.iana.org.

  ## What it does and does not touch

  Only the `delegated` list is fetched. The other three are curated by hand and
  are preserved verbatim, because none of them is derivable from IANA's file:

    * `second_level` — endings like `co.uk` and `ak.us`, which are registry
      policy rather than delegations, and appear in no IANA list.
    * `common` — the endings the typo engine prefers when ranking suggestions.
    * `special_use` — RFC 2606/6761 reserved endings (`localhost`, `invalid`,
      `internal`, …) plus `arpa`, which IANA does delegate but which holds no
      mailboxes. These are subtracted from the public set, so an entry here
      wins over the same entry in `delegated`.

  A `common` entry that IANA has stopped delegating fails the run rather than
  being dropped silently: it means a suggestion target has been retired, which
  is a judgement call rather than a mechanical update.
  """

  use Mix.Task

  @shortdoc "Regenerate the delegated TLD list in priv/tlds.json from IANA"

  @source_url "https://data.iana.org/TLD/tlds-alpha-by-domain.txt"
  @tlds_path Path.expand("../../../priv/tlds.json", __DIR__)

  @impl Mix.Task
  def run(args) do
    {opts, _rest, _invalid} = OptionParser.parse(args, strict: [check: :boolean])
    check_only = Keyword.get(opts, :check, false)

    Application.ensure_all_started(:req)

    current = read_current!()
    {version, delegated} = fetch_delegated!()

    added = delegated -- current["tlds"]["delegated"]
    removed = current["tlds"]["delegated"] -- delegated

    report(added, removed)
    verify_common!(current["tlds"]["common"], delegated)

    cond do
      added == [] and removed == [] ->
        Mix.shell().info("priv/tlds.json is already in sync with IANA #{version}.")

      check_only ->
        Mix.raise("priv/tlds.json is out of date. Run: mix tymeslot.sync_tlds")

      true ->
        write!(current, version, delegated)

        Mix.shell().info(
          "Wrote #{length(delegated)} delegated TLDs from IANA #{version}. " <>
            "Review and commit the diff."
        )
    end
  end

  @doc """
  Fetches IANA's delegated TLD list.

  Returns the file's version stamp and the endings, lowercased and sorted.
  Shared with `TldFreshnessTest`, which asserts the shipped file still matches
  what this returns.
  """
  @spec fetch_delegated!() :: {String.t(), [String.t()]}
  def fetch_delegated! do
    body =
      case Req.get(@source_url, receive_timeout: 30_000, retry: :transient) do
        {:ok, %Req.Response{status: 200, body: body}} ->
          body

        {:ok, %Req.Response{status: status}} ->
          Mix.raise("IANA returned HTTP #{status} for #{@source_url}")

        {:error, reason} ->
          Mix.raise("Could not reach #{@source_url}: #{Exception.message(reason)}")
      end

    lines = body |> String.split("\n", trim: true) |> Enum.map(&String.trim/1)

    version =
      case Enum.find(lines, &String.starts_with?(&1, "#")) do
        "# Version " <> rest -> rest |> String.split(",") |> List.first()
        _no_header -> "unknown"
      end

    delegated =
      lines
      |> Enum.reject(&String.starts_with?(&1, "#"))
      |> Enum.map(&String.downcase/1)
      |> Enum.sort()

    if length(delegated) < 1000 do
      Mix.raise("IANA returned only #{length(delegated)} endings — refusing to trust that")
    end

    {version, delegated}
  end

  defp read_current! do
    @tlds_path |> File.read!() |> JSON.decode!()
  end

  defp report([], []), do: :ok

  defp report(added, removed) do
    if added != [], do: Mix.shell().info("+ #{length(added)} added: #{preview(added)}")
    if removed != [], do: Mix.shell().info("- #{length(removed)} removed: #{preview(removed)}")
  end

  defp preview(endings) when length(endings) <= 12, do: Enum.join(endings, ", ")

  defp preview(endings) do
    Enum.join(Enum.take(endings, 12), ", ") <> ", … (#{length(endings) - 12} more)"
  end

  defp verify_common!(common, delegated) do
    case common -- delegated do
      [] ->
        :ok

      orphaned ->
        Mix.raise(
          "These `common` endings are no longer delegated by IANA: " <>
            Enum.join(orphaned, ", ") <>
            ". Decide what the typo engine should suggest instead, then edit " <>
            "priv/tlds.json by hand."
        )
    end
  end

  defp write!(current, version, delegated) do
    tlds =
      current["tlds"]
      |> Map.put("delegated", delegated)
      |> Map.take(["delegated", "second_level", "common", "special_use"])

    metadata = %{
      "last_updated" => Date.to_iso8601(Date.utc_today()),
      "iana_version" => version,
      "source" => @source_url,
      "delegated_count" => length(delegated)
    }

    # `max: 1` forces one entry per line. The default inlines short arrays,
    # which would reflow a whole bucket when a single ending is delegated and
    # bury the actual change in the diff.
    json = :json.format(%{"metadata" => metadata, "tlds" => tlds}, %{max: 1})

    File.write!(@tlds_path, IO.iodata_to_binary(json))
  end
end
