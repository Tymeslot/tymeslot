defmodule Tymeslot.Integrations.Calendar.Utils.SafeXmlAtomTest do
  @moduledoc """
  Pins that parsing remote XML never grows the atom table.

  CalDAV and EWS responses come from a server the user nominated. A parser
  that turns element, attribute or namespace-prefix names into atoms lets
  such a server fill the table, which is never garbage collected, until the
  VM aborts for every tenant on the node. Each entry point that reads remote
  XML is driven with a document of thousands of names never seen before.

  Not async: the atom table is global, and a concurrently running test
  creating atoms of its own would be counted against the parser.
  """

  use ExUnit.Case, async: false

  @moduletag :integrations
  @moduletag :calendar

  alias Tymeslot.Integrations.Calendar.CalDAV.SyncCollectionReport
  alias Tymeslot.Integrations.Calendar.CalDAV.XmlHandler
  alias Tymeslot.Integrations.Calendar.Exchange.Soap
  alias Tymeslot.Integrations.Calendar.Utils.SafeXml

  @unique_names 5_000

  # Far below `@unique_names`: a parser minting one atom per name grows the
  # table by thousands, while the constant overhead of a first call (a module
  # loaded, a code path taken for the first time) is a handful.
  @tolerated_growth 50

  test "SafeXml.parse/1 creates no atom per element, attribute or prefix name" do
    assert_no_atom_growth(fn body -> {:ok, _doc} = SafeXml.parse(body) end)
  end

  test "a CalDAV calendar-query response creates no atoms from its names" do
    assert_no_atom_growth(fn body -> {:ok, []} = XmlHandler.parse_calendar_query(body) end)
  end

  test "a CalDAV discovery response creates no atoms from its names" do
    assert_no_atom_growth(fn body -> {:ok, []} = XmlHandler.parse_calendar_discovery(body) end)
  end

  test "a CalDAV sync-collection response creates no atoms from its names" do
    assert_no_atom_growth(fn body ->
      {:ok, {[], [], nil}} = SyncCollectionReport.parse_response(body)
    end)
  end

  test "a CalDAV property probe creates no atoms from its names" do
    assert_no_atom_growth(fn body ->
      {:ok, nil} = SyncCollectionReport.parse_ctag_response(body)
    end)
  end

  test "an EWS SOAP response creates no atoms from its names" do
    assert_no_atom_growth(fn body -> {:ok, _doc} = Soap.parse(body) end)
  end

  defp assert_no_atom_growth(parse) do
    # Warm the path first, so loading the modules involved is not counted.
    parse.(hostile_document("warm"))

    body = hostile_document("n#{System.unique_integer([:positive])}x")
    before = :erlang.system_info(:atom_count)
    parse.(body)
    growth = :erlang.system_info(:atom_count) - before

    assert growth < @tolerated_growth,
           "parsing #{@unique_names} unique names grew the atom table by #{growth}"
  end

  # Every element carries a fresh namespace prefix, a namespaced local name,
  # an unprefixed and a prefixed attribute, and a fresh child element, so
  # each kind of name a parser could intern appears thousands of times over.
  defp hostile_document(seed) do
    names =
      for i <- 1..@unique_names, into: "" do
        tag = "#{seed}#{i}"

        ~s(<p#{tag}:e#{tag} xmlns:p#{tag}="urn:#{tag}" a#{tag}="1" p#{tag}:b#{tag}="2">) <>
          ~s(<c#{tag}/></p#{tag}:e#{tag}>)
      end

    ~s(<?xml version="1.0" encoding="UTF-8"?><root xmlns="urn:root">#{names}</root>)
  end
end
