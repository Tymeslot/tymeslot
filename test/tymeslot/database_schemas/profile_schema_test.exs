defmodule Tymeslot.DatabaseSchemas.ProfileSchemaTest do
  use Tymeslot.DataCase, async: true

  alias Tymeslot.DatabaseSchemas.ProfileSchema
  import Tymeslot.Factory

  describe "embed domain validation" do
    setup do
      user = insert(:user)
      {:ok, user: user}
    end

    test "validates domain format", %{user: user} do
      valid_domains = [
        "example.com",
        "subdomain.example.com",
        "my-site.org",
        "a.b.c.example.com",
        "localhost",
        "test123.com",
        "123test.com"
      ]

      for domain <- valid_domains do
        changeset =
          ProfileSchema.changeset(%ProfileSchema{}, %{
            user_id: user.id,
            timezone: "Europe/Kyiv",
            allowed_embed_domains: [domain]
          })

        assert changeset.valid?,
               "Expected #{domain} to be valid but got errors: #{inspect(changeset.errors)}"
      end
    end

    test "rejects invalid domain formats", %{user: user} do
      invalid_domains = [
        {"https://example.com", "protocol"},
        {"http://example.com", "protocol"},
        {"example.com/path", "path"},
        {"example.com?query=1", "query"},
        {"example.com#anchor", "anchor"},
        {"example.com:8080", "port"},
        {"user@example.com", "at symbol"},
        {"-example.com", "starts with hyphen"},
        {"example-.com", "ends with hyphen"},
        {"example", "no TLD"},
        {"*.example.com", "wildcard"},
        {"*.sub.example.net", "wildcard"}
        # Note: empty string is filtered out by normalization before validation
      ]

      for {domain, reason} <- invalid_domains do
        changeset =
          ProfileSchema.changeset(%ProfileSchema{}, %{
            user_id: user.id,
            timezone: "Europe/Kyiv",
            allowed_embed_domains: [domain]
          })

        refute changeset.valid?,
               "Expected #{domain} (#{reason}) to be invalid but changeset was valid"

        assert Keyword.has_key?(changeset.errors, :allowed_embed_domains),
               "Expected error on allowed_embed_domains for #{domain} (#{reason})"
      end
    end

    test "enforces maximum of 20 domains", %{user: user} do
      # 20 domains should be OK
      domains_20 = for i <- 1..20, do: "example#{i}.com"

      changeset_20 =
        ProfileSchema.changeset(%ProfileSchema{}, %{
          user_id: user.id,
          timezone: "Europe/Kyiv",
          allowed_embed_domains: domains_20
        })

      assert changeset_20.valid?

      # 21 domains should fail
      domains_21 = for i <- 1..21, do: "example#{i}.com"

      changeset_21 =
        ProfileSchema.changeset(%ProfileSchema{}, %{
          user_id: user.id,
          timezone: "Europe/Kyiv",
          allowed_embed_domains: domains_21
        })

      refute changeset_21.valid?
      assert Keyword.has_key?(changeset_21.errors, :allowed_embed_domains)

      {error_msg, _value} = changeset_21.errors[:allowed_embed_domains]
      assert error_msg =~ "cannot have more than 20"
    end

    test "enforces maximum domain length of 255 characters", %{user: user} do
      # 255 chars should be OK (need multiple labels, each max 63 chars)
      # Create a domain with multiple 63-char labels: aaa...aaa.bbb...bbb.ccc...ccc.com
      # 63 + 1 + 63 + 1 + 63 + 1 + 63 = 255 chars
      label_63 = String.duplicate("a", 63)
      domain_255 = "#{label_63}.#{label_63}.#{label_63}.#{String.duplicate("b", 63)}"
      assert byte_size(domain_255) == 255

      changeset_255 =
        ProfileSchema.changeset(%ProfileSchema{}, %{
          user_id: user.id,
          timezone: "Europe/Kyiv",
          allowed_embed_domains: [domain_255]
        })

      assert changeset_255.valid?,
             "Expected 255-char domain to be valid, errors: #{inspect(changeset_255.errors)}"

      # 256 chars should fail
      domain_256 = domain_255 <> "x"
      assert byte_size(domain_256) == 256

      changeset_256 =
        ProfileSchema.changeset(%ProfileSchema{}, %{
          user_id: user.id,
          timezone: "Europe/Kyiv",
          allowed_embed_domains: [domain_256]
        })

      refute changeset_256.valid?
      assert Keyword.has_key?(changeset_256.errors, :allowed_embed_domains)

      {error_msg, _value} = changeset_256.errors[:allowed_embed_domains]
      assert error_msg =~ "exceed maximum length"
    end

    test "handles mixed valid and invalid domains", %{user: user} do
      mixed_domains = [
        "valid.com",
        "https://invalid.com",
        "also-valid.org",
        "invalid@domain.com"
      ]

      changeset =
        ProfileSchema.changeset(%ProfileSchema{}, %{
          user_id: user.id,
          timezone: "Europe/Kyiv",
          allowed_embed_domains: mixed_domains
        })

      refute changeset.valid?
      assert Keyword.has_key?(changeset.errors, :allowed_embed_domains)
    end

    test "sanitizes unicode and emoji from domains", %{user: user} do
      # Unicode/emoji should be stripped by sanitizer, making domain invalid
      unicode_domains = [
        "example😀.com",
        "tëst.com",
        "例え.com"
      ]

      for domain <- unicode_domains do
        changeset =
          ProfileSchema.changeset(%ProfileSchema{}, %{
            user_id: user.id,
            timezone: "Europe/Kyiv",
            allowed_embed_domains: [domain]
          })

        # After sanitization, these should either be invalid or transformed
        refute changeset.valid?,
               "Expected #{domain} to be invalid after sanitization"
      end
    end

    test "allows empty list", %{user: user} do
      changeset =
        ProfileSchema.changeset(%ProfileSchema{}, %{
          user_id: user.id,
          timezone: "Europe/Kyiv",
          allowed_embed_domains: []
        })

      assert changeset.valid?
    end

    test "handles nil allowed_embed_domains", %{user: user} do
      changeset =
        ProfileSchema.changeset(%ProfileSchema{}, %{
          user_id: user.id,
          timezone: "Europe/Kyiv",
          allowed_embed_domains: nil
        })

      # Nil is acceptable as it will be cast to empty list
      assert changeset.valid?
    end

    test "validates multi-level subdomains", %{user: user} do
      multi_level_domains = [
        "a.example.com",
        "a.b.example.com",
        "a.b.c.example.com",
        "a.b.c.d.example.com"
      ]

      for domain <- multi_level_domains do
        changeset =
          ProfileSchema.changeset(%ProfileSchema{}, %{
            user_id: user.id,
            timezone: "Europe/Kyiv",
            allowed_embed_domains: [domain]
          })

        assert changeset.valid?, "Expected #{domain} to be valid"
      end
    end

    test "validates domains with numbers", %{user: user} do
      number_domains = [
        "123.example.com",
        "test123.com",
        "123test.org",
        "1-2-3.example.com"
      ]

      for domain <- number_domains do
        changeset =
          ProfileSchema.changeset(%ProfileSchema{}, %{
            user_id: user.id,
            timezone: "Europe/Kyiv",
            allowed_embed_domains: [domain]
          })

        assert changeset.valid?, "Expected #{domain} to be valid"
      end
    end

    test "rejects domain labels exceeding 63 characters", %{user: user} do
      # Create a label that's 64 characters
      long_label = String.duplicate("a", 64)
      domain = "#{long_label}.com"

      changeset =
        ProfileSchema.changeset(%ProfileSchema{}, %{
          user_id: user.id,
          timezone: "Europe/Kyiv",
          allowed_embed_domains: [domain]
        })

      refute changeset.valid?
    end

    test "accepts domain labels of exactly 63 characters", %{user: user} do
      # Create a label that's exactly 63 characters
      max_label = String.duplicate("a", 63)
      domain = "#{max_label}.com"

      changeset =
        ProfileSchema.changeset(%ProfileSchema{}, %{
          user_id: user.id,
          timezone: "Europe/Kyiv",
          allowed_embed_domains: [domain]
        })

      assert changeset.valid?
    end
  end

  describe "profile changeset" do
    test "requires user_id" do
      changeset = ProfileSchema.changeset(%ProfileSchema{}, %{})

      refute changeset.valid?
      assert Keyword.has_key?(changeset.errors, :user_id)
      # Note: timezone has a default value so it won't show in errors when empty
    end

    test "accepts valid profile data with embed domains" do
      user = insert(:user)

      changeset =
        ProfileSchema.changeset(%ProfileSchema{}, %{
          user_id: user.id,
          timezone: "Europe/Kyiv",
          username: "testuser",
          allowed_embed_domains: ["example.com", "test.org"]
        })

      assert changeset.valid?
    end
  end
end
