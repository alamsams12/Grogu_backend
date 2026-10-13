-- dev_testers_and_studios.sql
--
-- Development seed: 25 playtesters and 3 game studios.
--
-- DEV / STAGING ONLY. Every account here uses the shared password `playtest`
-- and an @example.com address. Do not run this against a database that holds
-- real users.
--
-- Accounts are created through `grogu_signup`, the same function the app's
-- signup form calls, so bcrypt hashing and the players/studios side rows are
-- created exactly as they are for real users. Fields that signup does not
-- accept (bio, languages, badges, founding year) are set afterwards.
--
-- Reputation is written as a "baseline" event through grogu_reputation_award
-- (migration 008), never straight into players.reputation, so the cached
-- number always equals the sum of the tester's reputation history. Profile
-- bonuses are then checked the same way the profile form would. Both run
-- with grogu.quiet on, so seeding raises no notifications.
--
-- Idempotent: an email that already exists is skipped, so re-running is safe.
--
-- Apply after db/migrations/*.sql:
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f db/seeds/001_dev_testers_and_studios.sql

BEGIN;

DO $seed$
DECLARE
  rec       jsonb;
  v_user_id integer;
BEGIN
  FOR rec IN
    SELECT value FROM jsonb_array_elements($json$
[
  {"role":"tester","name":"Amara Osei","email":"amara.osei@example.com","password":"playtest","location":"Accra, GH","experienceLevel":"hardcore","platforms":["pc","console"],"preferredGenres":["rpg","strategy"],"weeklyAvailabilityHours":12,"languages":["English","Twi"],"reputation":88,"badges":["Detailed reporter","Bug hunter"],"bio":"Turn-based and RPG player. I write up every encounter I can find."},
  {"role":"tester","name":"Lukas Schneider","email":"lukas.schneider@example.com","password":"playtest","location":"Berlin, DE","experienceLevel":"regular","platforms":["pc"],"preferredGenres":["puzzle","adventure"],"weeklyAvailabilityHours":6,"languages":["English","German"],"reputation":72,"badges":["Fast turnaround"],"bio":"Puzzle games and slow-burn adventures. Weekends are my testing time."},
  {"role":"tester","name":"Priya Raman","email":"priya.raman@example.com","password":"playtest","location":"Chennai, IN","experienceLevel":"professional","platforms":["pc","mac"],"preferredGenres":["simulation","strategy"],"weeklyAvailabilityHours":15,"languages":["English","Tamil"],"reputation":93,"badges":["Top 10%","Detailed reporter"],"bio":"Former QA engineer. I know what a useful bug report looks like."},
  {"role":"tester","name":"Mateo Ruiz","email":"mateo.ruiz@example.com","password":"playtest","location":"Mexico City, MX","experienceLevel":"casual","platforms":["mobile"],"preferredGenres":["puzzle","platformer"],"weeklyAvailabilityHours":4,"languages":["English","Spanish"],"reputation":55,"badges":["New tester"],"bio":"Mostly mobile games on the commute. Honest first impressions."},
  {"role":"tester","name":"Hannah Lee","email":"hannah.lee@example.com","password":"playtest","location":"Toronto, CA","experienceLevel":"hardcore","platforms":["pc","console"],"preferredGenres":["shooter","action"],"weeklyAvailabilityHours":10,"languages":["English","Korean"],"reputation":81,"badges":["Bug hunter"],"bio":"Competitive shooter player. I break balance before the patch notes do."},
  {"role":"tester","name":"Kwame Mensah","email":"kwame.mensah@example.com","password":"playtest","location":"London, UK","experienceLevel":"regular","platforms":["pc","console"],"preferredGenres":["action","platformer"],"weeklyAvailabilityHours":8,"languages":["English"],"reputation":67,"badges":["Fast turnaround"],"bio":"Platformers and action games. Controller in hand, every time."},
  {"role":"tester","name":"Sofia Lindqvist","email":"sofia.lindqvist@example.com","password":"playtest","location":"Stockholm, SE","experienceLevel":"professional","platforms":["pc","linux"],"preferredGenres":["roguelike","strategy"],"weeklyAvailabilityHours":14,"languages":["English","Swedish"],"reputation":90,"badges":["Top 10%","Bug hunter"],"bio":"Roguelike runs until the sun comes up. Balance is my favourite topic."},
  {"role":"tester","name":"Daniel Kim","email":"daniel.kim@example.com","password":"playtest","location":"Seoul, KR","experienceLevel":"hardcore","platforms":["pc"],"preferredGenres":["rpg","adventure"],"weeklyAvailabilityHours":9,"languages":["English","Korean"],"reputation":78,"badges":["Detailed reporter"],"bio":"Story-first RPG player who still reads every dialogue option."},
  {"role":"tester","name":"Fatima Al-Sayed","email":"fatima.alsayed@example.com","password":"playtest","location":"Cairo, EG","experienceLevel":"casual","platforms":["mobile","web"],"preferredGenres":["puzzle","simulation"],"weeklyAvailabilityHours":5,"languages":["English","Arabic"],"reputation":60,"badges":["New tester"],"bio":"Cozy games and browser puzzles. I notice when the tutorial is confusing."},
  {"role":"tester","name":"Oliver Smith","email":"oliver.smith@example.com","password":"playtest","location":"Manchester, UK","experienceLevel":"regular","platforms":["pc","console"],"preferredGenres":["horror","adventure"],"weeklyAvailabilityHours":7,"languages":["English"],"reputation":70,"badges":["Fast turnaround"],"bio":"Horror and atmospheric exploration. I scare easily but report honestly."},
  {"role":"tester","name":"Ana Souza","email":"ana.souza@example.com","password":"playtest","location":"Sao Paulo, BR","experienceLevel":"regular","platforms":["pc","mobile"],"preferredGenres":["simulation","puzzle"],"weeklyAvailabilityHours":6,"languages":["English","Portuguese"],"reputation":64,"badges":["New tester"],"bio":"Management sims and clever puzzles. Playing in short sessions."},
  {"role":"tester","name":"Tom Becker","email":"tom.becker@example.com","password":"playtest","location":"Vancouver, CA","experienceLevel":"hardcore","platforms":["pc"],"preferredGenres":["strategy","simulation"],"weeklyAvailabilityHours":11,"languages":["English","French"],"reputation":84,"badges":["Detailed reporter","Top 10%"],"bio":"Grand strategy and city builders. I keep spreadsheets of everything."},
  {"role":"tester","name":"Yuki Tanaka","email":"yuki.tanaka@example.com","password":"playtest","location":"Osaka, JP","experienceLevel":"casual","platforms":["mobile","console"],"preferredGenres":["platformer","adventure"],"weeklyAvailabilityHours":5,"languages":["English","Japanese"],"reputation":58,"badges":["New tester"],"bio":"Gentle platformers and story games on the couch."},
  {"role":"tester","name":"Chidi Eze","email":"chidi.eze@example.com","password":"playtest","location":"Lagos, NG","experienceLevel":"regular","platforms":["mobile","pc"],"preferredGenres":["action","roguelike"],"weeklyAvailabilityHours":8,"languages":["English"],"reputation":74,"badges":["Bug hunter","Fast turnaround"],"bio":"Roguelikes on the phone, action on the PC. Crash reports included."},
  {"role":"tester","name":"Elena Petrova","email":"elena.petrova@example.com","password":"playtest","location":"Warsaw, PL","experienceLevel":"professional","platforms":["pc","mac"],"preferredGenres":["rpg","strategy"],"weeklyAvailabilityHours":13,"languages":["English","Polish"],"reputation":91,"badges":["Top 10%","Detailed reporter"],"bio":"Ex-game designer. I test with a critic's eye and a player's patience."},
  {"role":"tester","name":"Jordan Brooks","email":"jordan.brooks@example.com","password":"playtest","location":"Austin, US","experienceLevel":"hardcore","platforms":["pc","console"],"preferredGenres":["shooter","horror"],"weeklyAvailabilityHours":10,"languages":["English"],"reputation":79,"badges":["Bug hunter"],"bio":"Late-night horror runs and co-op shooters. Streams on weekends."},
  {"role":"tester","name":"Ibrahim Diallo","email":"ibrahim.diallo@example.com","password":"playtest","location":"Dakar, SN","experienceLevel":"casual","platforms":["mobile"],"preferredGenres":["puzzle","adventure"],"weeklyAvailabilityHours":4,"languages":["English","French"],"reputation":52,"badges":["New tester"],"bio":"Puzzle and narrative games. I'm new to playtesting and learning fast."},
  {"role":"tester","name":"Mei Lin Chen","email":"meilin.chen@example.com","password":"playtest","location":"Singapore, SG","experienceLevel":"regular","platforms":["pc","web"],"preferredGenres":["simulation","adventure"],"weeklyAvailabilityHours":7,"languages":["English","Mandarin"],"reputation":69,"badges":["Detailed reporter"],"bio":"Cozy sims and browser adventures. I write a lot of notes."},
  {"role":"tester","name":"Samuel Okoro","email":"samuel.okoro@example.com","password":"playtest","location":"Houston, US","experienceLevel":"hardcore","platforms":["pc"],"preferredGenres":["strategy","rpg"],"weeklyAvailabilityHours":12,"languages":["English"],"reputation":86,"badges":["Top 10%","Fast turnaround"],"bio":"Tactics and CRPGs. Happy to replay a fight twenty times to get the numbers."},
  {"role":"tester","name":"Ingrid Haugen","email":"ingrid.haugen@example.com","password":"playtest","location":"Oslo, NO","experienceLevel":"regular","platforms":["pc","mac"],"preferredGenres":["adventure","puzzle"],"weeklyAvailabilityHours":6,"languages":["English","Norwegian"],"reputation":76,"badges":["Detailed reporter"],"bio":"Quiet exploration games and locked-room puzzles."},
  {"role":"tester","name":"Rafael Costa","email":"rafael.costa@example.com","password":"playtest","location":"Lisbon, PT","experienceLevel":"casual","platforms":["console"],"preferredGenres":["action","platformer"],"weeklyAvailabilityHours":5,"languages":["English","Portuguese"],"reputation":57,"badges":["New tester"],"bio":"Couch co-op and fun platformers. Keep it light and I'm happy."},
  {"role":"tester","name":"Zara Ahmed","email":"zara.ahmed@example.com","password":"playtest","location":"Karachi, PK","experienceLevel":"professional","platforms":["pc","linux"],"preferredGenres":["roguelike","rpg"],"weeklyAvailabilityHours":16,"languages":["English","Urdu"],"reputation":95,"badges":["Top 10%","Bug hunter","Detailed reporter"],"bio":"Full-time reviewer on the side. Logs every crash with the build hash."},
  {"role":"tester","name":"Connor Murphy","email":"connor.murphy@example.com","password":"playtest","location":"Dublin, IE","experienceLevel":"regular","platforms":["pc","console"],"preferredGenres":["shooter","action"],"weeklyAvailabilityHours":8,"languages":["English"],"reputation":71,"badges":["Fast turnaround"],"bio":"Shooters with friends on weeknights. I tell it like it is."},
  {"role":"tester","name":"Nadia Rahman","email":"nadia.rahman@example.com","password":"playtest","location":"Dhaka, BD","experienceLevel":"regular","platforms":["pc","mobile"],"preferredGenres":["puzzle","rpg"],"weeklyAvailabilityHours":6,"languages":["English","Bengali"],"reputation":66,"badges":["New tester"],"bio":"Puzzle games and long RPG campaigns. I write short, specific reports."},
  {"role":"tester","name":"Aiko Watanabe","email":"aiko.watanabe@example.com","password":"playtest","location":"Kyoto, JP","experienceLevel":"regular","platforms":["mobile","pc"],"preferredGenres":["puzzle","simulation"],"weeklyAvailabilityHours":6,"languages":["English","Japanese"],"reputation":65,"badges":["New tester"],"bio":"Puzzle games and relaxing sims. Careful with feedback on UI."}
]
$json$::jsonb) AS t(value)
  LOOP
    -- Skip accounts that already exist so the seed can be re-run.
    IF EXISTS (SELECT 1 FROM users WHERE lower(email) = lower(rec ->> 'email')) THEN
      CONTINUE;
    END IF;

    PERFORM grogu_signup(rec);

    SELECT id INTO v_user_id FROM users WHERE lower(email) = lower(rec ->> 'email');

    UPDATE users SET bio = rec ->> 'bio' WHERE id = v_user_id;

    UPDATE players
       SET languages  = grogu_jsonb_text_array(rec -> 'languages'),
           badges     = grogu_jsonb_text_array(rec -> 'badges')
     WHERE user_id = v_user_id;

    PERFORM set_config('grogu.quiet', 'on', true);
    PERFORM grogu_reputation_award(v_user_id, 'baseline', '', (rec ->> 'reputation')::int);
    PERFORM grogu_profile_check_bonuses(v_user_id);
    PERFORM set_config('grogu.quiet', 'off', true);
  END LOOP;
END
$seed$;

DO $seed$
DECLARE
  rec       jsonb;
  v_user_id integer;
BEGIN
  FOR rec IN
    SELECT value FROM jsonb_array_elements($json$
[
  {"role":"developer","name":"Lukas Brandt","email":"ember.forge@example.com","password":"playtest","location":"Hamburg, DE","studioName":"Ember Forge Studio","website":"https://emberforge.example","studioSize":"small","foundedYear":2019,"bio":"Ember Forge Studio on Grogu. Small team making tactical dungeon games."},
  {"role":"developer","name":"Henrik Varga","email":"tidewater@example.com","password":"playtest","location":"Montreal, CA","studioName":"Tidewater Interactive","website":"https://tidewater.example","studioSize":"mid","foundedYear":2014,"bio":"Tidewater Interactive on Grogu. Narrative and simulation games for PC and console."},
  {"role":"developer","name":"Ji-woo Park","email":"pixel.moth@example.com","password":"playtest","location":"Busan, KR","studioName":"Pixel Moth Games","website":"https://pixelmoth.example","studioSize":"solo","foundedYear":2022,"bio":"Pixel Moth Games on Grogu. Solo developer making small, weird platformers."}
]
$json$::jsonb) AS t(value)
  LOOP
    IF EXISTS (SELECT 1 FROM users WHERE lower(email) = lower(rec ->> 'email')) THEN
      CONTINUE;
    END IF;

    PERFORM grogu_signup(rec);

    SELECT id INTO v_user_id FROM users WHERE lower(email) = lower(rec ->> 'email');

    UPDATE users SET bio = rec ->> 'bio' WHERE id = v_user_id;

    UPDATE studios
       SET founded_year = (rec ->> 'foundedYear')::int
     WHERE user_id = v_user_id;
  END LOOP;
END
$seed$;

COMMIT;
