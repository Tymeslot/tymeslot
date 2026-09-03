defmodule Tymeslot.Profiles.ReservedPaths do
  @moduledoc """
  Encapsulates the logic for identifying reserved paths and usernames.
  This module separates the concern of namespace management from the broader profile context.
  """

  alias Tymeslot.Locales

  @doc """
  Returns a list of top-level paths and usernames that are reserved for system use.
  Includes system routes, security-sensitive terms, brand-related paths, and inappropriate content.
  """
  @spec list() :: [String.t()]
  def list do
    # Combine static paths from the web layer with domain-level reserved terms
    TymeslotWeb.static_paths() ++
      locale_paths() ++
      system_paths() ++
      brand_paths() ++
      security_paths() ++
      common_paths() ++
      offensive_paths()
  end

  # Supported locale codes can serve as top-level URL prefixes for localised
  # pages (/de, /fr, ...), so a username must never be able to shadow one —
  # or be shadowed by one — should a longer locale code ever launch.
  defp locale_paths, do: Locales.supported_codes()

  defp system_paths do
    ~w(
      auth dashboard api dev docs admin healthcheck webhooks email-change debug onboarding
      login logout signin sign-in signup sign-up register settings profile account password reset-password
      setup config configuration system root mail email billing subscription
      payment invoice plans pricing upgrade downgrade feedback report abuse
      webhook callback oauth connect integration marketplace apps plugins
      extensions themes templates layouts components assets static media
      uploads downloads files images icons fonts scripts styles
      meeting meetings meeting-request schedule user users www home app
    )
  end

  defp brand_paths do
    ~w(tymeslot timeslot tymeslot-app)
  end

  defp security_paths do
    ~w(test demo staging production local localhost internal private hidden)
  end

  defp common_paths do
    ~w(
      support help faq contact about legal privacy terms tos
      status blog news jobs careers press media download install
      search find explore discover categories tags topics groups community
      forum wiki documentation manual guide tutorial events
    )
  end

  defp offensive_paths do
    ~w(
      fuck fuk fck fucck fck fuk fuq fking fcking shit sht sh1t shyt shite
      ass arse azz @ss a55 bitch btch b1tch biatch byatch cunt cnt c0nt kunt
      dick dik d1ck dck cock cok c0ck cawk pussy puss psy pussie p0rn
      penis pen1s pnis vagina vag vajina bastard bstrd b@stard damn dmn dammit
      hell heck hel fck hell-hole whore wh0re hor hore slut slvt sl0t slutty

      nigger nigga n1gger n1gga nig nog negro negr0 faggot fag f@ggot f@g
      fgt fagot fags queer homo homosexual dyke tranny trannie retard retrd
      ret@rd r3tard retarded rtard rape raped raping rapist nazi nazi facist
      hitler hitleer h1tler adolf swastika kkk ku-klux-klan white-power

      porn pr0n p0rn prn pron porno pornography xxx xx xcx x-rated r-rated
      sex s3x sexx sexy seks fucking fking fck anal an@l a-nal oral 0ral
      blowjob blow-job bj fellatio handjob hand-job hj cumshot cum-shot
      orgasm 0rgasm climax ejaculate masturbate masterbate jerk-off jackoff

      asshole a55hole arsehole a-hole @sshole bullshit bull-shit bs b-s
      motherfucker mofo mtherfcker mother-fcker fucker fker fcking fucked
      shitty sh1tty crappy crap crp piss p1ss pissed pissing pisser urinate
      tits tities titties boobs b00bs boobies breasts brests hooters jugs
      testicles testacles balls ballsack scrotum anus an0s rectum butt

      jackass jack-ass jerk jrk douchebag douche douch dumbass dumb-ass
      dumb-fuck dumb-shit twat tw@t prick prck wanker wnker bollocks bugger
      goddamn god-damn damn-it damnit Jesus-Christ jfc Christ-sake wtf
      cunt-face dick-head dickhead shit-head shithead ass-hat asshat
      cock-sucker cocksucker mother-fucker mofo son-of-a-bitch soab sob

      kike k1ke kyke spic sp1c wetback wet-back beaner chink ch1nk gook
      g00k towel-head towelhead sand-nigger camel-jockey raghead terrorist
      jihadist jihad isis isil al-qaeda alqaeda taliban hamas hezbollah
      bomb bomber bombing kill killer killing murder murderer death die
      suicide suicidal hang hanging shoot shooter shooting stab stabbing

      drugs drug narcotic cocaine coke coca cokehead heroin smack junk
      meth methamphetamine crystal-meth amphetamine crack crack-cocaine
      weed pot marijuana cannabis ganja dope reefer joint blunt hash hashish
      ecstasy molly mdma lsd acid shrooms mushrooms ketamine special-k
      dealer drug-dealer pusher trafficker trafficking junkie addict

      prostitute prostitution hooker call-girl escort escorts brothel
      sex-worker stripper strip-club pole-dancer lap-dance pimp pimping
      panties underwear lingerie thong g-string bra brassiere undies knickers

      nude nudes naked nudity nsfw adult adults-only 18plus 18+ xxx-rated
      sex-tape sextape porn-hub pornhub only-fans onlyfans blacked blacked-com
      gangbang gang-bang threesome 3some foursome orgy orgies swinger swingers
      bdsm bondage fetish kink kinky dominatrix dungeon submissive

      incest inbred sibling-sex family-sex pedophile paedophile pedo pdo
      child-abuse child-porn kiddie-porn cp cheese-pizza lolita loli shota
      jailbait jail-bait barely-legal preteen pre-teen minor minors underage
      grooming groomer molester molestation predator

      scam scammer scamming fraud fraudster con con-artist phishing phish
      steal stealing stolen thief theft robbery hacked hacker hacking crack
      cracked cracker pirate pirated piracy warez keygen virus trojan
      malware spyware ransomware exploit exploits botnet ddos spam spammer
      ponzi pyramid-scheme money-laundering fake counterfeit forgery
    )
  end
end
