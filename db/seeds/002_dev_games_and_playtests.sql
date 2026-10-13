-- 002_dev_games_and_playtests.sql
--
-- Development seed: games and playtests in every lifecycle state, with
-- applications, test progress and feedback, so every screen has data.
--
-- DEV / STAGING ONLY. Run after the migrations and after
-- 001_dev_testers_and_studios.sql (it needs those accounts).
--
-- Everything goes through the same `grogu_*` functions the API calls: games are
-- saved, playtests are published, testers apply, studios decide, status moves
-- along the real transition table, testers download builds, tick tasks and
-- submit feedback. That keeps the data valid and generates the notifications
-- the app would have produced.
--
-- Tester indexes in the playtest specs refer to this list (1-based):
--   1  priya.nair@example.com (the demo tester), then the 25 testers from
--   001 in the order they were created.
--
-- Idempotent: a game or playtest whose title already exists is skipped.
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f db/seeds/002_dev_games_and_playtests.sql

BEGIN;

DO $seed$
DECLARE
  testers  integer[];
  spec     jsonb;
  input    jsonb;
  pt       jsonb;
  app      jsonb;
  dev_id   integer;
  game_id  integer;
  pt_id    integer;
  idx      integer;
  task_id  integer;
  label    text;
  step     text;
  final    text;
  created  timestamptz;
  v_build  text;
  v_notes  text;
  v_key    text;

  msgs text[] := ARRAY[
    'I play a lot of games in this genre and write detailed notes.',
    'Available this week and can test on my usual setup.',
    'Happy to record my session if that helps.',
    'I have experience testing early builds.',
    'Excited by the premise and keen to give structured feedback.',
    'I can test on both desktop and a handheld.',
    'I have played the previous version and can compare the changes.',
    'Looking forward to breaking things in a useful way.'
  ];
  devices text[] := ARRAY[
    'Windows PC, RTX 3060', 'MacBook Air M2', 'Steam Deck', 'PlayStation 5',
    'Android phone, Pixel 7', 'Windows laptop, integrated GPU', 'Linux desktop', 'iPhone 14'
  ];

  tasksets jsonb := $json$
  {
    "balance": [
      {"title":"Complete the target section on Normal","description":"Play from a fresh save and note where it stops being fun.","type":"objective","required":true,"estimatedMinutes":60},
      {"title":"Replay on the hardest difficulty","description":"Tell us whether the extra challenge feels fair.","type":"objective","required":false,"estimatedMinutes":45},
      {"title":"Rate the encounters","description":"A short survey on the encounters you played.","type":"survey","required":true,"estimatedMinutes":10},
      {"title":"Log any bugs","description":"Crashes, glitches, anything that felt broken.","type":"bug-report","required":false,"estimatedMinutes":15}
    ],
    "onboarding": [
      {"title":"Play the first thirty minutes without outside help","description":"Do not read guides. We want to see where you get stuck.","type":"objective","required":true,"estimatedMinutes":30},
      {"title":"Note where you were unsure what to do","description":"Describe the first moment the game was unclear.","type":"survey","required":true,"estimatedMinutes":10},
      {"title":"Log any bugs","description":"Crashes, glitches, anything that felt broken.","type":"bug-report","required":false,"estimatedMinutes":15}
    ],
    "narrative": [
      {"title":"Play through the branch in one sitting","description":"Take your time and read everything.","type":"objective","required":true,"estimatedMinutes":90},
      {"title":"Answer the story questionnaire","description":"What landed, what confused you, what you would change.","type":"survey","required":true,"estimatedMinutes":15},
      {"title":"Free play: try a different choice","description":"Replay a decision differently and compare.","type":"free-play","required":false,"estimatedMinutes":30}
    ],
    "compat": [
      {"title":"Install and launch on your device","description":"Follow the install notes and tell us if anything blocks you.","type":"objective","required":true,"estimatedMinutes":15},
      {"title":"Play three levels","description":"Note performance, input and layout issues.","type":"objective","required":true,"estimatedMinutes":30},
      {"title":"Report device-specific bugs","description":"Include your device model and OS version.","type":"bug-report","required":true,"estimatedMinutes":15}
    ],
    "general": [
      {"title":"Play for at least an hour","description":"Play the way you normally would.","type":"objective","required":true,"estimatedMinutes":60},
      {"title":"Share your overall impressions","description":"What worked, what did not, and what you would change.","type":"survey","required":true,"estimatedMinutes":10},
      {"title":"Log any bugs","description":"Crashes, glitches, anything that felt broken.","type":"bug-report","required":false,"estimatedMinutes":15}
    ]
  }
  $json$::jsonb;

  -- Twelve reviews: five positive, four neutral, three negative. A tester gets
  -- reviews[(tester index + playtest id) % 12] so the mix varies per playtest.
  reviews jsonb := $json$
  [
    {"ratings":{"fun":5,"difficulty":3,"clarity":4,"performance":5,"polish":4},"sentiment":"positive","summary":"The core loop clicked within the first twenty minutes. I kept finding reasons to play one more round.","highlights":["Satisfying core loop","Great audio feedback"],"painPoints":["Menu navigation is slow with a controller"],"bugs":[],"hoursPlayed":3.5,"wouldRecommend":true},
    {"ratings":{"fun":4,"difficulty":3,"clarity":5,"performance":4,"polish":4},"sentiment":"positive","summary":"Clear onboarding and a strong sense of progression. Controls felt responsive on my setup.","highlights":["Clear onboarding","Responsive controls"],"painPoints":["Some tooltips overlap on smaller screens"],"bugs":["Tooltip overlaps the inventory panel at 1366x768"],"hoursPlayed":2.5,"wouldRecommend":true},
    {"ratings":{"fun":5,"difficulty":4,"clarity":4,"performance":4,"polish":5},"sentiment":"positive","summary":"Visually the most polished build I have tested this year. A few balance spikes in the middle section.","highlights":["Excellent art direction","Memorable boss encounter"],"painPoints":["Difficulty spikes sharply in the third area"],"bugs":[],"hoursPlayed":4,"wouldRecommend":true},
    {"ratings":{"fun":4,"difficulty":2,"clarity":4,"performance":5,"polish":4},"sentiment":"positive","summary":"Runs smoothly and the difficulty curve is gentle. I would like a bit more challenge later on.","highlights":["Stable performance","Gentle ramp-up"],"painPoints":["Late game feels too easy"],"bugs":[],"hoursPlayed":3,"wouldRecommend":true},
    {"ratings":{"fun":5,"difficulty":3,"clarity":5,"performance":4,"polish":5},"sentiment":"positive","summary":"A thoughtful, well-paced experience with writing that respects the player.","highlights":["Strong writing","Good pacing"],"painPoints":[],"bugs":[],"hoursPlayed":5,"wouldRecommend":true},
    {"ratings":{"fun":3,"difficulty":3,"clarity":3,"performance":4,"polish":3},"sentiment":"neutral","summary":"Fun in short bursts but the loop gets repetitive after an hour. It needs more variety.","highlights":["Solid fundamentals"],"painPoints":["Repetitive objectives","Not enough variation between runs"],"bugs":[],"hoursPlayed":2,"wouldRecommend":true},
    {"ratings":{"fun":3,"difficulty":4,"clarity":2,"performance":4,"polish":3},"sentiment":"neutral","summary":"Interesting idea, but the game rarely explains its systems. I had to experiment to understand what mattered.","highlights":["Interesting systems"],"painPoints":["Systems are poorly explained","Tutorial skips key mechanics"],"bugs":[],"hoursPlayed":2.5,"wouldRecommend":true},
    {"ratings":{"fun":4,"difficulty":3,"clarity":3,"performance":3,"polish":3},"sentiment":"neutral","summary":"Enjoyable overall. Frame rate dipped in busy scenes and a couple of UI screens felt unfinished.","highlights":["Enjoyable core idea"],"painPoints":["Frame drops in busy scenes","Unfinished UI screens"],"bugs":["Frame rate drops below 30 in the market area"],"hoursPlayed":3,"wouldRecommend":true},
    {"ratings":{"fun":3,"difficulty":3,"clarity":4,"performance":2,"polish":3},"sentiment":"neutral","summary":"Controls are fine but performance on my laptop was rough. It might be fine on better hardware.","highlights":["Readable UI"],"painPoints":["Long load times","Stutter when entering new areas"],"bugs":["Stutter every time a new area loads"],"hoursPlayed":1.5,"wouldRecommend":false},
    {"ratings":{"fun":2,"difficulty":4,"clarity":2,"performance":3,"polish":2},"sentiment":"negative","summary":"I struggled to see what the game wanted from me. I stopped after about forty minutes.","highlights":[],"painPoints":["No clear goal in the first hour","Overwhelming number of systems"],"bugs":[],"hoursPlayed":1,"wouldRecommend":false},
    {"ratings":{"fun":2,"difficulty":5,"clarity":3,"performance":2,"polish":2},"sentiment":"negative","summary":"Too punishing, and the save system cost me progress twice. I would not recommend this build yet.","highlights":["Interesting art style"],"painPoints":["Unfair difficulty spikes","Autosave lost progress"],"bugs":["Autosave overwrote the previous slot after a crash","Game crashes when pausing during a cutscene"],"hoursPlayed":2,"wouldRecommend":false},
    {"ratings":{"fun":2,"difficulty":3,"clarity":2,"performance":3,"polish":3},"sentiment":"negative","summary":"The first impression was weak. Menus are confusing and the opening has too much text.","highlights":[],"painPoints":["Confusing menus","Text-heavy opening"],"bugs":["Menu focus gets stuck after returning from settings"],"hoursPlayed":1,"wouldRecommend":false}
  ]
  $json$::jsonb;
BEGIN
  -- Index 1 is the demo tester; the rest are the seeded testers in creation order.
  SELECT array_agg(id ORDER BY (email = 'priya.nair@example.com') DESC, id)
    INTO testers
    FROM users
   WHERE role = 'Player' AND email LIKE '%@example.com';

  IF coalesce(array_length(testers, 1), 0) < 26 THEN
    RAISE EXCEPTION 'Expected at least 26 seeded testers. Run 001_dev_testers_and_studios.sql first.';
  END IF;

  /* ------------------------------------------------------------------ */
  /*  Games                                                              */
  /* ------------------------------------------------------------------ */
  FOR spec IN SELECT value FROM jsonb_array_elements($json$
  [
    {"developer":"ember.forge@example.com","title":"Cinderhold","tagline":"Descend, adapt, and hold the line","description":"A tactical dungeon crawler where every floor rewrites the rules of the last. Build a party, manage heat and fuel, and decide when to retreat.","genres":["rpg","strategy","roguelike"],"platforms":["pc","linux"],"status":"beta","accentHue":18,"buildVersion":"0.9.2"},
    {"developer":"ember.forge@example.com","title":"Ashen Vows","tagline":"Every oath has a price","description":"A third-person action RPG built around weighty melee combat and a branching oath system that changes how enemies behave.","genres":["action","rpg"],"platforms":["pc","console"],"status":"alpha","accentHue":8,"buildVersion":"0.4.0"},
    {"developer":"ember.forge@example.com","title":"Slagrunner","tagline":"Sprint through the molten dark","description":"A fast roguelike platformer set inside a collapsing foundry. Short runs, sharp movement, and a heat meter that punishes hesitation.","genres":["roguelike","platformer"],"platforms":["pc"],"status":"in-development","accentHue":28,"buildVersion":"0.1.0"},
    {"developer":"tidewater@example.com","title":"Saltmarsh","tagline":"A coastal town, one decision at a time","description":"A narrative simulation about running a failing harbour town. Every conversation shifts alliances, and every season brings new pressure.","genres":["simulation","adventure"],"platforms":["pc","mac","console"],"status":"beta","accentHue":190,"buildVersion":"1.2.0"},
    {"developer":"tidewater@example.com","title":"The Long Harbour","tagline":"Some journeys end where they began","description":"A quiet narrative adventure about a lighthouse keeper and the letters that arrive by tide. Released, with ongoing accessibility improvements.","genres":["adventure","puzzle"],"platforms":["pc","console"],"status":"released","accentHue":205,"buildVersion":"1.0.3"},
    {"developer":"tidewater@example.com","title":"Tideline Tycoon","tagline":"Build a shipping empire on a budget","description":"A management sim about running a small shipping company, balancing contracts, crews and fuel against unpredictable weather.","genres":["simulation","strategy"],"platforms":["pc","web"],"status":"alpha","accentHue":170,"buildVersion":"0.6.5"},
    {"developer":"tidewater@example.com","title":"Undertow","tagline":"Something is breathing beneath the pier","description":"A slow-burn horror adventure on an abandoned fishing platform. Light, sound and pacing carry the dread.","genres":["horror","adventure"],"platforms":["pc"],"status":"beta","accentHue":220,"buildVersion":"0.8.0"},
    {"developer":"pixel.moth@example.com","title":"Moth Mansion","tagline":"Follow the light, mind the dark","description":"A cosy puzzle platformer where you play a moth exploring a mansion, using light and shadow to open the way forward.","genres":["platformer","puzzle"],"platforms":["pc","web","mobile"],"status":"beta","accentHue":275,"buildVersion":"0.7.1"},
    {"developer":"pixel.moth@example.com","title":"Lamplight Leap","tagline":"One tap. One jump. One more try.","description":"A one-button mobile platformer with hand-built levels and a calm soundtrack.","genres":["platformer"],"platforms":["mobile","web"],"status":"released","accentHue":50,"buildVersion":"1.1.0"},
    {"developer":"pixel.moth@example.com","title":"Bug Sprint","tagline":"Squash them before the build ships","description":"A fast arcade shooter in which you are a QA intern fending off glitches, one bug at a time.","genres":["shooter","action"],"platforms":["web","mobile"],"status":"alpha","accentHue":120,"buildVersion":"0.3.2"},
    {"developer":"mara@driftwoodgames.dev","title":"Tidepool Keeper","tagline":"Tend a tiny living world","description":"A cosy management game about caring for a tidepool ecosystem through the seasons.","genres":["simulation","adventure"],"platforms":["pc","mac"],"status":"beta","accentHue":160,"buildVersion":"0.5.0"}
  ]
  $json$::jsonb) LOOP
    SELECT id INTO dev_id FROM users WHERE email = spec ->> 'developer';
    IF dev_id IS NULL THEN
      RAISE EXCEPTION 'Studio % not found. Run 001_dev_testers_and_studios.sql and the migrations first.', spec ->> 'developer';
    END IF;

    IF NOT EXISTS (SELECT 1 FROM games WHERE developer_user_id = dev_id AND title = spec ->> 'title') THEN
      PERFORM grogu_game_save(dev_id, NULL, spec);
    END IF;
  END LOOP;

  /* ------------------------------------------------------------------ */
  /*  Playtests                                                          */
  /* ------------------------------------------------------------------ */
  FOR spec IN SELECT value FROM jsonb_array_elements($json$
  [
    {"developer":"ember.forge@example.com","game":"Cinderhold","title":"Cinderhold: dungeon 3 balance pass","summary":"We rebuilt the third dungeon and want to know where the difficulty curve breaks.","goals":["Find the encounter where the difficulty curve breaks","Rate the three new enemy types"],"focusAreas":["difficulty-balance","level-design"],"status":"recruiting","maxTesters":12,"closesInDays":4,"ageDays":6,"tasks":"balance","reward":"Steam key + name in the credits","cashReward":500,"requirements":{"minExperienceLevel":"hardcore","platforms":["pc","linux"],"preferredGenres":["rpg","strategy"],"languages":["English"],"minReputation":40,"estimatedHours":6,"ndaRequired":false},"accepted":[2,6,9],"rejected":[],"pending":[3,8,13,16,20,24],"reviewers":[]},
    {"developer":"ember.forge@example.com","game":"Cinderhold","title":"Cinderhold: co-op prototype","summary":"A closed test of the new two-player mode. Expect rough edges and frequent updates.","goals":["Stress-test matchmaking and reconnects","Judge whether co-op pacing feels fair"],"focusAreas":["multiplayer","performance"],"status":"in-progress","maxTesters":6,"closesInDays":-5,"ageDays":20,"tasks":"balance","reward":"Alpha access + paid sessions","cashReward":1200,"requirements":{"minExperienceLevel":"professional","platforms":["pc"],"preferredGenres":["strategy"],"languages":["English"],"minReputation":70,"estimatedHours":5,"ndaRequired":true},"accepted":[4,8,16,20,23,2],"rejected":[13,24],"pending":[],"reviewers":[4,16,23]},
    {"developer":"ember.forge@example.com","game":"Ashen Vows","title":"Ashen Vows: combat feel","summary":"Is melee combat satisfying, readable and fair? We are tuning hit reactions and want fresh eyes.","goals":["Judge the weight of light and heavy attacks","Tell us when an enemy attack felt unfair"],"focusAreas":["general","ui-ux"],"status":"recruiting","maxTesters":20,"closesInDays":18,"ageDays":3,"tasks":"general","reward":"Early access key","requirements":{"minExperienceLevel":"regular","platforms":["pc","console"],"preferredGenres":["action","rpg"],"languages":["English"],"minReputation":0,"estimatedHours":3,"ndaRequired":false},"accepted":[7,12,14],"rejected":[],"pending":[1,5,11,17,22,25],"reviewers":[]},
    {"developer":"ember.forge@example.com","game":"Slagrunner","title":"Slagrunner: first-hour onboarding","summary":"A draft: we are still deciding what to ask testers about the opening hour.","goals":["See whether the controls teach themselves"],"focusAreas":["onboarding"],"status":"draft","maxTesters":10,"closesInDays":21,"ageDays":1,"tasks":"onboarding","reward":"Free copy at launch","requirements":{"minExperienceLevel":"casual","platforms":["pc"],"preferredGenres":["platformer"],"languages":["English"],"minReputation":0,"estimatedHours":2,"ndaRequired":false},"accepted":[],"rejected":[],"pending":[],"reviewers":[]},

    {"developer":"tidewater@example.com","game":"Saltmarsh","title":"Saltmarsh: narrative branch review","summary":"We have finished the winter storyline and are collecting reviews before we lock the script.","goals":["Judge whether the choices feel meaningful","Flag dialogue that confuses or contradicts"],"focusAreas":["narrative"],"status":"review","maxTesters":10,"closesInDays":-10,"ageDays":28,"tasks":"narrative","reward":"Credits + store credit","cashReward":800,"requirements":{"minExperienceLevel":"regular","platforms":["pc","mac"],"preferredGenres":["adventure","simulation"],"languages":["English"],"minReputation":0,"estimatedHours":5,"ndaRequired":false},"accepted":[1,3,10,19,21,26,12],"rejected":[5],"pending":[],"reviewers":[1,3,19,21,26]},
    {"developer":"tidewater@example.com","game":"The Long Harbour","title":"The Long Harbour: accessibility pass","summary":"We shipped, and now we want to make the game easier to read, navigate and enjoy for everyone.","goals":["Find UI that is hard to read or operate","Test the new subtitle and colour options"],"focusAreas":["ui-ux","onboarding"],"status":"completed","maxTesters":12,"closesInDays":-40,"ageDays":60,"tasks":"onboarding","reward":"Name in credits + gift card","cashReward":600,"requirements":{"minExperienceLevel":"casual","platforms":["pc","console"],"preferredGenres":["adventure","puzzle"],"languages":["English"],"minReputation":0,"estimatedHours":3,"ndaRequired":false},"accepted":[2,4,7,10,11,14,15,18,22,24,25,13],"rejected":[],"pending":[],"reviewers":[2,4,7,10,11,14,15,18,22,25]},
    {"developer":"tidewater@example.com","game":"Tideline Tycoon","title":"Tideline Tycoon: economy balance","summary":"We need experienced players to find the dominant strategy before it finds our players.","goals":["Break the economy","Tell us which contracts feel mandatory"],"focusAreas":["difficulty-balance","ui-ux"],"status":"recruiting","maxTesters":8,"closesInDays":25,"ageDays":2,"tasks":"balance","reward":"Beta key + paid sessions","cashReward":1500,"requirements":{"minExperienceLevel":"hardcore","platforms":["pc","web"],"preferredGenres":["simulation","strategy"],"languages":["English"],"minReputation":60,"estimatedHours":8,"ndaRequired":false},"accepted":[13,20],"rejected":[],"pending":[4,8,16,23,26,2],"reviewers":[]},
    {"developer":"tidewater@example.com","game":"Undertow","title":"Undertow: horror pacing","summary":"A closed test under NDA. We are tuning how long the dread builds before the first scare.","goals":["Note the moment tension peaks","Tell us if the audio ever feels unfair"],"focusAreas":["general","performance"],"status":"recruiting","maxTesters":10,"closesInDays":2,"ageDays":10,"tasks":"general","reward":"Early access key","requirements":{"minExperienceLevel":"regular","platforms":["pc"],"preferredGenres":["horror"],"languages":["English"],"minReputation":60,"estimatedHours":4,"ndaRequired":true},"accepted":[11,17],"rejected":[10,1],"pending":[6,15,24,3],"reviewers":[]},
    {"developer":"tidewater@example.com","game":"The Long Harbour","title":"The Long Harbour: launch regression","summary":"A short regression check before the release patch. Closed early once the patch was approved.","goals":["Confirm the save system is stable","Check the new chapter select"],"focusAreas":["general"],"status":"closed","maxTesters":6,"closesInDays":-25,"ageDays":35,"tasks":"general","reward":"Credits","requirements":{"minExperienceLevel":"regular","platforms":["pc"],"preferredGenres":["adventure"],"languages":["English"],"minReputation":0,"estimatedHours":2,"ndaRequired":false},"accepted":[3,9,12,20],"rejected":[],"pending":[],"reviewers":[3,9]},
    {"developer":"tidewater@example.com","game":"Saltmarsh","title":"Saltmarsh: alpha loop","summary":"The first test of the season loop. Archived now, kept for reference.","goals":["Judge whether a season feels worth playing"],"focusAreas":["general","onboarding"],"status":"archived","maxTesters":8,"closesInDays":-95,"ageDays":110,"tasks":"onboarding","reward":"Credits","requirements":{"minExperienceLevel":"casual","platforms":["pc"],"preferredGenres":["simulation"],"languages":["English"],"minReputation":0,"estimatedHours":3,"ndaRequired":false},"accepted":[5,10,14,18,21,25],"rejected":[],"pending":[],"reviewers":[5,10,14,18,21]},

    {"developer":"pixel.moth@example.com","game":"Moth Mansion","title":"Moth Mansion: controller feel","summary":"Do jumps and light puzzles feel right on keyboard, pad and touch? Short sessions are fine.","goals":["Judge jump height and air control","Tell us which input method felt best"],"focusAreas":["general","level-design"],"status":"recruiting","maxTesters":8,"closesInDays":10,"ageDays":4,"tasks":"general","reward":"Free copy + credits","requirements":{"minExperienceLevel":"casual","platforms":["pc","web","mobile"],"preferredGenres":["platformer","puzzle"],"languages":["English"],"minReputation":0,"estimatedHours":2,"ndaRequired":false},"accepted":[5,14,18,1],"rejected":[],"pending":[22,10],"reviewers":[]},
    {"developer":"pixel.moth@example.com","game":"Lamplight Leap","title":"Lamplight Leap: Android compatibility","summary":"We are widening device support. Test on whatever Android or iOS device you own.","goals":["Find devices where the game stutters","Check touch targets on small screens"],"focusAreas":["performance","ui-ux"],"status":"in-progress","maxTesters":10,"closesInDays":-3,"ageDays":15,"tasks":"compat","reward":"Gift card","cashReward":400,"requirements":{"minExperienceLevel":"casual","platforms":["mobile"],"preferredGenres":["platformer"],"languages":["English"],"minReputation":0,"estimatedHours":2,"ndaRequired":false},"accepted":[5,15,18,22,14],"rejected":[],"pending":[],"reviewers":[15,18,14]},
    {"developer":"pixel.moth@example.com","game":"Bug Sprint","title":"Bug Sprint: first playable","summary":"Our first public build. Is the first minute clear and fun?","goals":["Tell us if the first minute makes sense","Tell us what you wanted to do but could not"],"focusAreas":["onboarding","general"],"status":"recruiting","maxTesters":15,"closesInDays":30,"ageDays":1,"tasks":"onboarding","reward":"Credits","requirements":{"minExperienceLevel":"casual","platforms":["web","mobile"],"preferredGenres":["shooter","action"],"languages":["English"],"minReputation":0,"estimatedHours":1,"ndaRequired":false},"accepted":[22],"rejected":[],"pending":[5,12,25],"reviewers":[]},

    {"developer":"mara@driftwoodgames.dev","game":"Tidepool Keeper","title":"Tidepool Keeper: cozy loop","summary":"Does tending the tidepool feel relaxing, or does it turn into chores? Completed; results are in.","goals":["Judge whether the daily loop feels relaxing","Find the point where it becomes repetitive"],"focusAreas":["general","narrative"],"status":"completed","maxTesters":8,"closesInDays":-30,"ageDays":45,"tasks":"general","reward":"Steam key + credit in the shipped game","requirements":{"minExperienceLevel":"casual","platforms":["pc","mac"],"preferredGenres":["simulation"],"languages":["English"],"minReputation":0,"estimatedHours":3,"ndaRequired":false},"accepted":[12,19,21,25,3,10],"rejected":[],"pending":[],"reviewers":[12,19,21,25,3,10]}
  ]
  $json$::jsonb) LOOP
    -- How testers get the game. The link is a placeholder on a reserved domain;
    -- NDA playtests also get a deterministic access key.
    v_build := 'https://builds.example.com/'
               || trim(both '-' from lower(regexp_replace(spec ->> 'game', '[^A-Za-z0-9]+', '-', 'g')))
               || '/' || substr(md5(spec ->> 'title'), 1, 8);
    v_notes := 'Download the build from the link and unzip it. Launch the game from the extracted folder.'
               || E'\n\nIf it will not start, update your graphics drivers first. '
               || 'Please do not share the build outside this playtest.';
    v_key   := CASE WHEN (spec -> 'requirements' ->> 'ndaRequired')::boolean
                    THEN 'BETA-' || upper(substr(md5(spec ->> 'title'), 1, 8)) ELSE '' END;

    -- Already seeded: only fill in access details that are still blank.
    IF EXISTS (SELECT 1 FROM playtests WHERE title = spec ->> 'title') THEN
      UPDATE playtests
         SET build_url = v_build, install_instructions = v_notes, access_key = v_key
       WHERE title = spec ->> 'title' AND build_url = '';
      CONTINUE;
    END IF;

    SELECT id INTO dev_id FROM users WHERE email = spec ->> 'developer';
    SELECT id INTO game_id FROM games WHERE developer_user_id = dev_id AND title = spec ->> 'game';
    IF game_id IS NULL THEN
      RAISE EXCEPTION 'Game "%" not found for %.', spec ->> 'game', spec ->> 'developer';
    END IF;

    final := spec ->> 'status';
    input := spec || jsonb_build_object(
      'gameId',   game_id,
      'publish',  final <> 'draft',
      'tasks',    tasksets -> (spec ->> 'tasks'),
      'closesAt', now() + (spec ->> 'closesInDays')::int * interval '1 day',
      'buildUrl', v_build,
      'installInstructions', v_notes,
      'accessKey', v_key
    );
    pt    := grogu_playtest_save(dev_id, NULL, input);
    pt_id := (pt ->> 'id')::int;

    -- Applications are only accepted while a playtest is recruiting, so they
    -- all happen before the status moves on.
    FOREACH label IN ARRAY ARRAY['accepted', 'rejected', 'pending'] LOOP
      FOR idx IN SELECT value::int FROM jsonb_array_elements_text(coalesce(spec -> label, '[]'::jsonb)) LOOP
        app := grogu_application_create(testers[idx], pt_id, jsonb_build_object(
          'agreedToTerms', true,
          'message',       msgs[1 + (idx + pt_id) % 8],
          'device',        devices[1 + idx % 8],
          'experienceNote', ''));

        IF label <> 'pending' THEN
          PERFORM grogu_application_decide(dev_id, (app ->> 'id')::int, label, NULL);
        END IF;
      END LOOP;
    END LOOP;

    FOREACH step IN ARRAY (CASE final
        WHEN 'in-progress' THEN ARRAY['in-progress']
        WHEN 'review'      THEN ARRAY['in-progress', 'review']
        WHEN 'completed'   THEN ARRAY['in-progress', 'review', 'completed']
        WHEN 'closed'      THEN ARRAY['in-progress', 'closed']
        WHEN 'archived'    THEN ARRAY['in-progress', 'review', 'completed', 'archived']
        ELSE ARRAY[]::text[] END) LOOP
      PERFORM grogu_playtest_set_status(dev_id, pt_id, step);
    END LOOP;

    -- Accepted testers download the build. Reviewers finish every task and
    -- submit feedback; the rest are left part-way through.
    FOR idx IN SELECT value::int FROM jsonb_array_elements_text(coalesce(spec -> 'accepted', '[]'::jsonb)) LOOP
      PERFORM grogu_test_download(testers[idx], pt_id);

      IF (spec -> 'reviewers') @> to_jsonb(idx) THEN
        FOR task_id IN SELECT id FROM playtest_tasks WHERE playtest_id = pt_id ORDER BY position LOOP
          PERFORM grogu_test_toggle_task(testers[idx], pt_id, task_id);
        END LOOP;
        PERFORM grogu_feedback_submit(testers[idx], pt_id, reviews -> ((idx + pt_id) % 12));
      ELSE
        SELECT id INTO task_id FROM playtest_tasks WHERE playtest_id = pt_id ORDER BY position LIMIT 1;
        PERFORM grogu_test_toggle_task(testers[idx], pt_id, task_id);
      END IF;
    END LOOP;

    -- Spread the timeline out so charts and "recent" lists are not all today.
    created := now() - (spec ->> 'ageDays')::int * interval '1 day';
    UPDATE playtests SET created_at = created, opens_at = created WHERE id = pt_id;
    UPDATE applications
       SET created_at = least(now(), created + (1 + id % 3) * interval '1 day'),
           decided_at = CASE WHEN decided_at IS NULL THEN NULL
                             ELSE least(now(), created + (2 + id % 3) * interval '1 day') END
     WHERE playtest_id = pt_id;
    UPDATE feedback
       SET created_at = least(now(), created + (4 + id % 5) * interval '1 day')
     WHERE playtest_id = pt_id;
  END LOOP;
END
$seed$;

COMMIT;
