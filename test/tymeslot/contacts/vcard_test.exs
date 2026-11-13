defmodule Tymeslot.Contacts.VCardTest do
  use ExUnit.Case, async: true

  @moduletag :integrations

  alias Tymeslot.Contacts.VCard

  test "reads the formatted name and every address, lowercased, in card order" do
    card = """
    BEGIN:VCARD\r
    VERSION:4.0\r
    N:Lovelace;Ada;;;\r
    FN:Ada Lovelace\r
    EMAIL;TYPE=work:Ada@Example.com\r
    item1.EMAIL;TYPE=INTERNET:ada@home.example\r
    TEL:+44 20 1234\r
    END:VCARD\r
    """

    assert VCard.parse(card) == %{
             name: "Ada Lovelace",
             emails: ["ada@example.com", "ada@home.example"]
           }
  end

  test "unfolds folded lines and unescapes text values" do
    card = "BEGIN:VCARD\nFN:Grace\\, Admiral\n  Hopper\nEMAIL:grace@\n example.com\nEND:VCARD\n"

    assert VCard.parse(card) == %{name: "Grace, Admiral Hopper", emails: ["grace@example.com"]}
  end

  test "keeps one of each address and drops empty ones" do
    card = "BEGIN:VCARD\nFN:Ada\nEMAIL:ada@example.com\nEMAIL:\nemail:ADA@example.com\nEND:VCARD"

    assert VCard.parse(card) == %{name: "Ada", emails: ["ada@example.com"]}
  end

  test "a card without a name or anything that is not a card yields nothing to break on" do
    assert VCard.parse("BEGIN:VCARD\nEMAIL:x@example.com\nEND:VCARD") ==
             %{name: nil, emails: ["x@example.com"]}

    assert VCard.parse("not a card") == %{name: nil, emails: []}
    assert VCard.parse(nil) == %{name: nil, emails: []}
  end
end
