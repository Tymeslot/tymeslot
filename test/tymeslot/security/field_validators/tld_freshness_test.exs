defmodule Tymeslot.Security.FieldValidators.TldFreshnessTest do
  @moduledoc """
  Guards the shipped TLD snapshot against IANA.

  `TLDList` rejects any ending absent from `priv/tlds.json`, so drift here is
  not untidiness: every ending IANA has delegated since the file was last
  synced is an address this build refuses. Excluded from default runs because
  it needs the network; the nightly `Excluded suites` workflow is what makes it
  bite.
  """

  use ExUnit.Case, async: true

  @moduletag :security
  @moduletag :tld_freshness

  alias Mix.Tasks.Tymeslot.SyncTlds
  alias Tymeslot.Security.FieldValidators.TLDList

  test "every ending IANA delegates is accepted by the shipped list" do
    {_version, delegated} = SyncTlds.fetch_delegated!()

    # `arpa` is delegated but reserved in `special_use`: infrastructure, no
    # mailboxes. It is the one entry expected to be refused.
    refused =
      Enum.reject(delegated, fn ending ->
        ending == "arpa" or TLDList.validate_tld(ending, "Email") == :ok
      end)

    assert refused == [],
           "priv/tlds.json is behind IANA and this build refuses " <>
             "#{length(refused)} delegated endings (#{Enum.join(Enum.take(refused, 10), ", ")}). " <>
             "Run: mix tymeslot.sync_tlds"
  end

  test "the shipped list carries nothing IANA has retired" do
    {_version, delegated} = SyncTlds.fetch_delegated!()
    known = Map.new(delegated, &{&1, true})

    # Only single-label endings are IANA's to delegate; `second_level` entries
    # like co.uk are registry policy and appear in no IANA list.
    phantom =
      Enum.reject(TLDList.public_tlds(), fn ending ->
        String.contains?(ending, ".") or Map.has_key?(known, ending)
      end)

    assert phantom == [],
           "priv/tlds.json accepts #{length(phantom)} endings IANA does not delegate " <>
             "(#{Enum.join(Enum.take(phantom, 10), ", ")}). Run: mix tymeslot.sync_tlds"
  end
end
