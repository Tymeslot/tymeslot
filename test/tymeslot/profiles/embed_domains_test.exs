defmodule Tymeslot.Profiles.EmbedDomainsTest do
  use Tymeslot.DataCase, async: true
  @moduletag :profiles

  alias Tymeslot.Profiles
  import Tymeslot.Factory

  describe "update_allowed_embed_domains/2" do
    setup do
      user = insert(:user)
      profile = insert(:profile, user: user, allowed_embed_domains: [])
      {:ok, profile: profile}
    end

    test "successfully updates with valid domains", %{profile: profile} do
      domains = ["example.com", "test.org", "subdomain.example.com"]

      assert {:ok, updated_profile} = Profiles.update_allowed_embed_domains(profile, domains)
      assert length(updated_profile.allowed_embed_domains) == 3
      assert "example.com" in updated_profile.allowed_embed_domains
      assert "test.org" in updated_profile.allowed_embed_domains
      assert "subdomain.example.com" in updated_profile.allowed_embed_domains
    end

    test "accepts comma-separated string", %{profile: profile} do
      assert {:ok, updated_profile} =
               Profiles.update_allowed_embed_domains(profile, "example.com, test.org")

      assert length(updated_profile.allowed_embed_domains) == 2
      assert "example.com" in updated_profile.allowed_embed_domains
      assert "test.org" in updated_profile.allowed_embed_domains
    end

    test "normalizes domains to lowercase", %{profile: profile} do
      assert {:ok, updated_profile} =
               Profiles.update_allowed_embed_domains(profile, ["EXAMPLE.COM", "Test.ORG"])

      assert "example.com" in updated_profile.allowed_embed_domains
      assert "test.org" in updated_profile.allowed_embed_domains
    end

    test "trims whitespace from domains", %{profile: profile} do
      assert {:ok, updated_profile} =
               Profiles.update_allowed_embed_domains(profile, [" example.com ", "  test.org  "])

      assert "example.com" in updated_profile.allowed_embed_domains
      assert "test.org" in updated_profile.allowed_embed_domains
    end

    test "removes duplicate domains", %{profile: profile} do
      assert {:ok, updated_profile} =
               Profiles.update_allowed_embed_domains(profile, [
                 "example.com",
                 "example.com",
                 "test.org"
               ])

      assert length(updated_profile.allowed_embed_domains) == 2
    end

    test "allows empty list to clear domains", %{profile: profile} do
      # First set some domains
      {:ok, profile} =
        Profiles.update_allowed_embed_domains(profile, ["example.com", "test.org"])

      # Then clear them
      assert {:ok, updated_profile} = Profiles.update_allowed_embed_domains(profile, [])
      assert updated_profile.allowed_embed_domains == []
    end

    test "rejects domains with protocols", %{profile: profile} do
      assert {:error, changeset} =
               Profiles.update_allowed_embed_domains(profile, ["https://example.com"])

      assert changeset.errors[:allowed_embed_domains] != nil
    end

    test "rejects domains with paths", %{profile: profile} do
      assert {:error, changeset} =
               Profiles.update_allowed_embed_domains(profile, ["example.com/path"])

      assert changeset.errors[:allowed_embed_domains] != nil
    end

    test "rejects domains with ports", %{profile: profile} do
      assert {:error, changeset} =
               Profiles.update_allowed_embed_domains(profile, ["example.com:8080"])

      assert changeset.errors[:allowed_embed_domains] != nil
    end

    test "accepts wildcard subdomain patterns", %{profile: profile} do
      assert {:ok, updated_profile} =
               Profiles.update_allowed_embed_domains(profile, ["*.example.com"])

      assert "*.example.com" in updated_profile.allowed_embed_domains
    end

    test "rejects invalid wildcard patterns", %{profile: profile} do
      assert {:error, changeset} =
               Profiles.update_allowed_embed_domains(profile, ["*.com"])

      assert changeset.errors[:allowed_embed_domains] != nil
    end

    test "rejects domains with @ symbol", %{profile: profile} do
      assert {:error, changeset} =
               Profiles.update_allowed_embed_domains(profile, ["user@example.com"])

      assert changeset.errors[:allowed_embed_domains] != nil
    end

    test "rejects domains exceeding 255 characters", %{profile: profile} do
      long_domain = String.duplicate("a", 256) <> ".com"

      assert {:error, changeset} = Profiles.update_allowed_embed_domains(profile, [long_domain])
      assert changeset.errors[:allowed_embed_domains] != nil
      assert elem(changeset.errors[:allowed_embed_domains], 0) =~ "exceed maximum length"
    end

    test "rejects more than 20 domains", %{profile: profile} do
      domains = for i <- 1..21, do: "example#{i}.com"

      assert {:error, changeset} = Profiles.update_allowed_embed_domains(profile, domains)
      assert changeset.errors[:allowed_embed_domains] != nil
      assert elem(changeset.errors[:allowed_embed_domains], 0) =~ "cannot have more than 20"
    end

    test "accepts exactly 20 domains", %{profile: profile} do
      domains = for i <- 1..20, do: "example#{i}.com"

      assert {:ok, updated_profile} = Profiles.update_allowed_embed_domains(profile, domains)
      assert length(updated_profile.allowed_embed_domains) == 20
    end

    test "allows localhost for development", %{profile: profile} do
      assert {:ok, updated_profile} =
               Profiles.update_allowed_embed_domains(profile, ["localhost"])

      assert "localhost" in updated_profile.allowed_embed_domains
    end

    test "strips emoji and unicode from domains", %{profile: profile} do
      # Emoji should be stripped by sanitizer, resulting in invalid domain
      assert {:error, changeset} =
               Profiles.update_allowed_embed_domains(profile, ["example😀.com"])

      assert changeset.errors[:allowed_embed_domains] != nil
    end

    test "handles domains with hyphens", %{profile: profile} do
      assert {:ok, updated_profile} =
               Profiles.update_allowed_embed_domains(profile, ["my-domain.com", "test-site.org"])

      assert "my-domain.com" in updated_profile.allowed_embed_domains
      assert "test-site.org" in updated_profile.allowed_embed_domains
    end

    test "handles multi-level subdomains", %{profile: profile} do
      assert {:ok, updated_profile} =
               Profiles.update_allowed_embed_domains(profile, [
                 "a.b.c.example.com",
                 "sub1.sub2.test.org"
               ])

      assert "a.b.c.example.com" in updated_profile.allowed_embed_domains
      assert "sub1.sub2.test.org" in updated_profile.allowed_embed_domains
    end

    test "rejects single-label domains (except localhost)", %{profile: profile} do
      assert {:error, changeset} = Profiles.update_allowed_embed_domains(profile, ["example"])
      assert changeset.errors[:allowed_embed_domains] != nil
    end

    test "rejects domains starting with hyphen", %{profile: profile} do
      assert {:error, changeset} =
               Profiles.update_allowed_embed_domains(profile, ["-example.com"])

      assert changeset.errors[:allowed_embed_domains] != nil
    end

    test "rejects domains ending with hyphen", %{profile: profile} do
      assert {:error, changeset} =
               Profiles.update_allowed_embed_domains(profile, ["example-.com"])

      assert changeset.errors[:allowed_embed_domains] != nil
    end

    test "filters out empty strings from list", %{profile: profile} do
      assert {:ok, updated_profile} =
               Profiles.update_allowed_embed_domains(profile, ["example.com", "", "test.org", ""])

      assert length(updated_profile.allowed_embed_domains) == 2
      assert "example.com" in updated_profile.allowed_embed_domains
      assert "test.org" in updated_profile.allowed_embed_domains
    end

    test "handles comma-separated string with extra whitespace", %{profile: profile} do
      assert {:ok, updated_profile} =
               Profiles.update_allowed_embed_domains(
                 profile,
                 "  example.com ,  test.org  , subdomain.example.com  "
               )

      assert length(updated_profile.allowed_embed_domains) == 3
      assert "example.com" in updated_profile.allowed_embed_domains
    end
  end

  describe "add_embed_domains/2" do
    setup do
      user = insert(:user)
      profile = insert(:profile, user: user, allowed_embed_domains: ["existing.com"])
      {:ok, profile: profile}
    end

    test "parses comma-separated input and merges with existing", %{profile: profile} do
      assert {:ok, ["existing.com", "new.com", "other.org"]} =
               Profiles.add_embed_domains(profile, "new.com, other.org")
    end

    test "returns :empty_input for blank string", %{profile: profile} do
      assert {:error, :empty_input} = Profiles.add_embed_domains(profile, "  , , ")
    end

    test "returns :duplicates when input overlaps existing domains", %{profile: profile} do
      assert {:error, {:duplicates, ["existing.com"]}} =
               Profiles.add_embed_domains(profile, "existing.com, new.com")
    end

    test "duplicate check is case-insensitive", %{profile: profile} do
      assert {:error, {:duplicates, ["existing.com"]}} =
               Profiles.add_embed_domains(profile, "EXISTING.COM")
    end

    test "treats [\"none\"] as empty existing list", %{profile: profile} do
      profile = %{profile | allowed_embed_domains: ["none"]}

      assert {:ok, ["new.com"]} = Profiles.add_embed_domains(profile, "new.com")
    end

    test "deduplicates within the input itself", %{profile: profile} do
      assert {:ok, ["existing.com", "new.com"]} =
               Profiles.add_embed_domains(profile, "new.com, NEW.COM, new.com")
    end

    test "handles nil existing domains", %{profile: profile} do
      profile = %{profile | allowed_embed_domains: nil}

      assert {:ok, ["new.com"]} = Profiles.add_embed_domains(profile, "new.com")
    end
  end
end
