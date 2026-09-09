#!/usr/bin/env node
// One-off: seed the English dictation word bank. Originally a curated 40-word
// starter set; extended (2026-09-09) to the full ~187-word list from the
// "PSLE 英语拼写易错词表" artifact (https://claude.ai/code/artifact/961a7e7f-b75e-4f05-bcba-0daac9aba08b),
// covering every word across all 9 of that artifact's categories. That
// artifact's own per-word "tip" text is NOT reused as the dictation sentence —
// those tips are Chinese-language spelling explanations that name the tricky
// letters outright (e.g. "别漏了中间不发音的 d"), which would hand the kid the
// answer. Every sentence below is freshly written: English-only, uses the
// word naturally in a plain P6-level context, and never spells out or hints
// at the word's tricky letters — the whole point of a dictation exercise.
//
// Run against a scratch DB first, then against the live Mac Mini once
// verified. Idempotent-ish: re-running will 409 on duplicates (same
// word+level), which this script just logs and skips.
//
// Usage: HOST=127.0.0.1 PORT=2099 ADMIN_PIN=1234 node tools/english-dictation/seed-words.js

const HOST = process.env.HOST || "127.0.0.1";
const PORT = process.env.PORT || "2021";
const ADMIN_PIN = process.env.ADMIN_PIN;
if (!ADMIN_PIN) {
  console.error("ADMIN_PIN env var is required");
  process.exit(1);
}

const WORDS = [
  ["handkerchief", "She folded the handkerchief neatly and put it in her pocket.", "Silent Letters"],
  ["knowledge", "Reading gives you a lot of useful knowledge.", "Silent Letters"],
  ["foreign", "My uncle works for a foreign company in Japan.", "Silent Letters"],
  ["vehicle", "The fire engine is a very large vehicle.", "Silent Letters"],
  ["scissors", "Please use the scissors carefully when you cut the paper.", "Silent Letters"],
  ["receipt", "Keep the receipt in case you need to return the item.", "Silent Letters"],
  ["island", "Sentosa is a small island near Singapore.", "Silent Letters"],
  ["listen", "You need to listen carefully during the exam instructions.", "Silent Letters"],
  ["climb", "The children love to climb the tree in the park.", "Silent Letters"],
  ["Wednesday", "Our school holds assembly every Wednesday morning.", "Silent Letters"],
  ["necessary", "It is necessary to bring an umbrella when it rains.", "Double Letters"],
  ["occurred", "The accident occurred just before the traffic light.", "Double Letters"],
  ["beginning", "The story has an exciting beginning.", "Double Letters"],
  ["embarrassed", "He felt embarrassed when he forgot his lines.", "Double Letters"],
  ["committee", "The committee will meet on Friday to plan the event.", "Double Letters"],
  ["accommodate", "The hotel can accommodate up to two hundred guests.", "Double Letters"],
  ["disappear", "The magician made the coin disappear.", "Double Letters"],
  ["immediately", "Please come to the office immediately.", "Double Letters"],
  ["successful", "Her presentation was very successful.", "Double Letters"],
  ["recommend", "I would recommend this book to every student.", "Double Letters"],
  ["separate", "Please keep your wet clothes in a separate bag.", "Tricky Vowels"],
  ["definitely", "I will definitely finish my homework tonight.", "Tricky Vowels"],
  ["business", "My father runs a small business near our house.", "Tricky Vowels"],
  ["government", "The government announced a new policy today.", "Tricky Vowels"],
  ["environment", "We should all take care of the environment.", "Tricky Vowels"],
  ["February", "My birthday is in February.", "Tricky Vowels"],
  ["guarantee", "The shop cannot guarantee that the toy will not break.", "Tricky Vowels"],
  ["rhythm", "The drummer kept a steady rhythm throughout the song.", "Tricky Vowels"],
  ["responsible", "Every pupil is responsible for keeping the classroom clean.", "Word Endings"],
  ["existence", "Scientists are still studying the existence of new planets.", "Word Endings"],
  ["maintenance", "The lift is closed today for maintenance.", "Word Endings"],
  ["believe", "I believe you can do well if you try your best.", "ie vs ei"],
  ["receive", "You will receive your results next Monday.", "ie vs ei"],
  ["weird", "It felt weird to be back in school after the holidays.", "ie vs ei"],
  ["neighbour", "Our neighbour waters our plants when we go on holiday.", "ie vs ei"],
  ["unnecessary", "Try not to make unnecessary noise in the library.", "Prefixes"],
  ["disappoint", "He did not want to disappoint his parents.", "Prefixes"],
  ["irregular", "This verb has an irregular past tense.", "Prefixes"],
  ["though", "It was raining, though the sky looked bright.", "-ough Family"],
  ["through", "The ball rolled through the small gap in the fence.", "-ough Family"],

  // --- Extension (2026-09-09): the rest of the artifact's word list ---

  ["honest", "It is always better to be honest, even when the truth is hard to say.", "Silent Letters"],
  ["calm", "The teacher told us to stay calm during the fire drill.", "Silent Letters"],
  ["half", "She ate half of the sandwich and saved the rest for later.", "Silent Letters"],
  ["sword", "The knight in the story carried a long sword.", "Silent Letters"],
  ["gnaw", "The puppy loves to gnaw on its favourite toy.", "Silent Letters"],
  ["campaign", "The school started a campaign to reduce plastic waste.", "Silent Letters"],
  ["castle", "We visited an old castle during our trip to England.", "Silent Letters"],
  ["fasten", "Please fasten your seatbelt before the car starts moving.", "Silent Letters"],
  ["whistle", "The referee blew his whistle to stop the game.", "Silent Letters"],
  ["doubt", "I have no doubt that she will win the competition.", "Silent Letters"],
  ["debt", "He worked hard every month to pay off his debt.", "Silent Letters"],
  ["plumber", "The plumber came to fix the leaking pipe in our kitchen.", "Silent Letters"],
  ["subtle", "There was a subtle difference between the two paintings.", "Silent Letters"],
  ["sign", "The sign at the entrance said the shop was closed.", "Silent Letters"],
  ["honour", "It was a great honour to receive the award on stage.", "Silent Letters"],

  ["professional", "She gave a very professional presentation to the whole class.", "Double Letters"],
  ["possession", "Losing his favourite watch felt like losing a prized possession.", "Double Letters"],
  ["occasion", "We only use the good plates on a special occasion.", "Double Letters"],
  ["exaggerate", "He tends to exaggerate how difficult his homework was.", "Double Letters"],
  ["appreciate", "I really appreciate all the help you gave me today.", "Double Letters"],
  ["apparent", "It was apparent from her smile that she had good news.", "Double Letters"],
  ["interrupt", "Please do not interrupt me while I am speaking.", "Double Letters"],
  ["millionaire", "The old man in the story turned out to be a millionaire.", "Double Letters"],
  ["horrible", "The weather during our camping trip was absolutely horrible.", "Double Letters"],
  ["collect", "The children love to collect seashells along the beach.", "Double Letters"],
  ["suddenly", "The lights suddenly went out during the storm.", "Double Letters"],
  ["swimming", "My favourite activity during the holidays is swimming.", "Double Letters"],
  ["running", "He injured his ankle while running in the relay race.", "Double Letters"],
  ["planning", "Our class is planning a trip to the science museum.", "Double Letters"],
  ["stopping", "The bus was stopping at every corner because of traffic.", "Double Letters"],

  ["stationary", "The car remained stationary at the traffic light for a long time.", "Confusable Pairs"],
  ["stationery", "She bought new stationery, including pencils and erasers, for school.", "Confusable Pairs"],
  ["principal", "The principal gave a speech during the school assembly.", "Confusable Pairs"],
  ["principle", "Honesty is an important principle that guides how she treats others.", "Confusable Pairs"],
  ["compliment", "He gave his teacher a compliment on her interesting lesson.", "Confusable Pairs"],
  ["complement", "The red scarf was a perfect complement to her blue dress.", "Confusable Pairs"],
  ["affect", "The rainy weather did not affect our plans for the picnic.", "Confusable Pairs"],
  ["effect", "The medicine had an immediate effect on his headache.", "Confusable Pairs"],
  ["desert", "Camels are well suited to living in the hot desert.", "Confusable Pairs"],
  ["dessert", "We had ice cream for dessert after dinner.", "Confusable Pairs"],
  ["quiet", "The library was completely quiet during the exam.", "Confusable Pairs"],
  ["quite", "The test was quite difficult, but I managed to finish it.", "Confusable Pairs"],
  ["lose", "I hope our team does not lose the final match.", "Confusable Pairs"],
  ["loose", "His shoelaces were loose, so he stopped to tie them.", "Confusable Pairs"],
  ["advice", "My grandfather always gives me useful advice about life.", "Confusable Pairs"],
  ["advise", "The doctor will advise you on how to recover quickly.", "Confusable Pairs"],
  ["practice", "Football practice was cancelled because of the heavy rain.", "Confusable Pairs"],
  ["practise", "You need to practise the piano every day to improve.", "Confusable Pairs"],
  ["weather", "The weather forecast predicted heavy rain for the weekend.", "Confusable Pairs"],
  ["whether", "I am not sure whether we should bring an umbrella.", "Confusable Pairs"],
  ["personal", "She kept a personal diary to write about her day.", "Confusable Pairs"],
  ["personnel", "Only authorised personnel are allowed to enter that room.", "Confusable Pairs"],
  ["formally", "The chairman formally opened the new community centre.", "Confusable Pairs"],
  ["formerly", "This building was formerly used as a post office.", "Confusable Pairs"],
  ["later", "We can finish this project later in the afternoon.", "Confusable Pairs"],
  ["latter", "Of the two books, I preferred the latter one.", "Confusable Pairs"],
  ["cloth", "She wiped the table with a damp cloth.", "Confusable Pairs"],
  ["clothes", "He packed his clothes neatly into the suitcase.", "Confusable Pairs"],
  ["altar", "The couple stood at the altar during the wedding ceremony.", "Confusable Pairs"],
  ["alter", "The tailor had to alter the dress so it would fit properly.", "Confusable Pairs"],
  ["bare", "He walked across the hot sand with bare feet.", "Confusable Pairs"],
  ["bear", "We saw a brown bear at the zoo last weekend.", "Confusable Pairs"],
  ["except", "Everyone finished the assignment except one student.", "Confusable Pairs"],
  ["accept", "She was happy to accept the invitation to the party.", "Confusable Pairs"],
  ["cite", "The student had to cite the book she used for her essay.", "Confusable Pairs"],
  ["site", "The construction site was surrounded by a tall fence.", "Confusable Pairs"],

  ["temperature", "The nurse checked his temperature before letting him go home.", "Tricky Vowels"],
  ["restaurant", "We celebrated my birthday at our favourite restaurant.", "Tricky Vowels"],
  ["vegetable", "Broccoli is my little sister's favourite vegetable.", "Tricky Vowels"],
  ["queue", "We had to stand in a long queue to buy the tickets.", "Tricky Vowels"],
  ["similar", "The two paintings looked so similar that I could not tell them apart.", "Tricky Vowels"],
  ["interesting", "The documentary about space was really interesting.", "Tricky Vowels"],
  ["different", "Each student in the class had a different opinion about the book.", "Tricky Vowels"],
  ["experience", "Visiting the museum was an unforgettable experience for the whole class.", "Tricky Vowels"],
  ["beautiful", "The sunset over the ocean was absolutely beautiful.", "Tricky Vowels"],
  ["courageous", "The firefighter was praised for being courageous during the rescue.", "Tricky Vowels"],
  ["pronunciation", "Her pronunciation of the difficult word was perfectly clear.", "Tricky Vowels"],
  ["occasionally", "He occasionally forgets to bring his water bottle to school.", "Tricky Vowels"],
  ["mathematics", "Mathematics is his strongest subject in school.", "Tricky Vowels"],
  ["awkward", "There was an awkward silence after he forgot his lines.", "Tricky Vowels"],
  ["privilege", "It was a privilege to be chosen to represent the school.", "Tricky Vowels"],
  ["vacuum", "My mother asked me to vacuum the living room carpet.", "Tricky Vowels"],
  ["yacht", "The wealthy businessman sailed around the world on his yacht.", "Tricky Vowels"],

  ["possible", "It is possible to finish the project if we work together.", "Word Endings"],
  ["visible", "The mountain peak was clearly visible from our hotel window.", "Word Endings"],
  ["comfortable", "The new sofa in the living room is very comfortable.", "Word Endings"],
  ["reasonable", "The price of the toy seemed reasonable for its quality.", "Word Endings"],
  ["occurrence", "A power outage during a storm is not an unusual occurrence.", "Word Endings"],
  ["convenience", "The shop stays open late for the convenience of its customers.", "Word Endings"],
  ["appearance", "She was nervous about her appearance before the school photo.", "Word Endings"],
  ["performance", "The class gave an outstanding performance at the concert.", "Word Endings"],
  ["valuable", "The old coin turned out to be extremely valuable.", "Word Endings"],
  ["available", "There were only two seats available for the last show.", "Word Endings"],
  ["knowledgeable", "Our tour guide was very knowledgeable about the ancient ruins.", "Word Endings"],
  ["confidence", "Winning the competition gave her a lot of confidence.", "Word Endings"],
  ["difference", "There is a big difference between the two answers.", "Word Endings"],
  ["audience", "The audience clapped loudly after the final act.", "Word Endings"],
  ["patience", "Teaching young children requires a great deal of patience.", "Word Endings"],
  ["absence", "The teacher noticed his absence from class immediately.", "Word Endings"],

  ["achieve", "She worked hard every day to achieve her dream of becoming a doctor.", "ie vs ei"],
  ["deceive", "He would never try to deceive his friends about anything.", "ie vs ei"],
  ["height", "The height of the building made it visible from far away.", "ie vs ei"],
  ["friend", "She has been my best friend since kindergarten.", "ie vs ei"],
  ["field", "The football field was covered in mud after the rain.", "ie vs ei"],
  ["piece", "He gave me a piece of cake from his birthday celebration.", "ie vs ei"],
  ["ceiling", "There was a large crack running across the ceiling.", "ie vs ei"],
  ["eight", "The shop opens at eight o'clock every morning.", "ie vs ei"],

  ["misspell", "It is easy to misspell long words if you write too quickly.", "Prefixes"],
  ["irresponsible", "It would be irresponsible to leave the campfire burning unattended.", "Prefixes"],
  ["illegal", "Parking in front of the fire station is illegal.", "Prefixes"],
  ["immature", "His immature behaviour surprised his classmates during the meeting.", "Prefixes"],
  ["unbelievable", "The magician's final trick was absolutely unbelievable.", "Prefixes"],
  ["irrelevant", "That question was irrelevant to the topic we were discussing.", "Prefixes"],
  ["disagree", "The two brothers often disagree about which movie to watch.", "Prefixes"],
  ["innumerable", "There were innumerable stars visible in the night sky.", "Prefixes"],
  ["inconvenient", "The road closure was inconvenient for everyone travelling to work.", "Prefixes"],
  ["unnatural", "The bright colour of the drink looked completely unnatural.", "Prefixes"],
  ["misunderstand", "I hope you did not misunderstand what I meant to say.", "Prefixes"],

  ["especially", "I enjoy all sports, especially swimming and badminton.", "Everyday Words"],
  ["until", "We waited at the bus stop until the rain stopped.", "Everyday Words"],
  ["across", "She swam across the pool without stopping to rest.", "Everyday Words"],
  ["tomorrow", "Our school sports day has been postponed until tomorrow.", "Everyday Words"],
  ["surprise", "The class planned a surprise party for their teacher's birthday.", "Everyday Words"],
  ["twelfth", "Today is the twelfth of the month.", "Everyday Words"],
  ["eighth", "This is the eighth chapter of the novel we are reading.", "Everyday Words"],
  ["library", "I borrowed three books from the school library.", "Everyday Words"],
  ["probably", "It will probably rain later this afternoon.", "Everyday Words"],
  ["because", "He was late for school because his bicycle had a flat tyre.", "Everyday Words"],
  ["calendar", "She marked the date of the exam on her calendar.", "Everyday Words"],
  ["grammar", "Our English teacher spent the lesson explaining a grammar rule.", "Everyday Words"],
  ["tongue", "The spicy soup made his tongue feel like it was burning.", "Everyday Words"],
  ["guess", "Can you guess how many sweets are in the jar?", "Everyday Words"],
  ["guide", "The tour guide showed us around the old temple.", "Everyday Words"],
  ["guitar", "He has been learning to play the guitar for two years.", "Everyday Words"],
  ["weight", "The doctor recorded his height and weight during the check-up.", "Everyday Words"],
  ["straight", "Draw a straight line from one corner of the page to the other.", "Everyday Words"],

  ["thorough", "The inspector did a thorough check of the entire building.", "-ough Family"],
  ["thought", "I thought the movie was much better than the book.", "-ough Family"],
  ["bought", "She bought a new pair of shoes for the school concert.", "-ough Family"],
  ["brought", "He brought his umbrella because the sky looked cloudy.", "-ough Family"],
  ["fought", "The two knights fought bravely in the story.", "-ough Family"],
  ["caught", "The goalkeeper caught the ball just before it crossed the line.", "-ough Family"],
  ["taught", "My grandmother taught me how to bake bread.", "-ough Family"],
  ["daughter", "The old fisherman took his daughter out to sea for the first time.", "-ough Family"],
  ["enough", "We did not have enough time to finish the whole test.", "-ough Family"],
  ["cough", "He had a bad cough, so he stayed home from school.", "-ough Family"],
  ["rough", "The surface of the rock felt rough under my fingers.", "-ough Family"],
];

async function main() {
  let created = 0, skipped = 0, failed = 0;
  for (const [word, sentence, topic] of WORDS) {
    const res = await fetch(`http://${HOST}:${PORT}/api/vocab`, {
      method: "POST",
      headers: { "Content-Type": "application/json", "X-Admin-Pin": ADMIN_PIN },
      body: JSON.stringify({ language: "en", word, sentence, level: "P6", topic }),
    });
    if (res.status === 201) {
      created++;
    } else if (res.status === 409) {
      skipped++;
      console.log(`skip (already exists): ${word}`);
    } else {
      failed++;
      console.error(`FAILED (${res.status}): ${word} — ${await res.text()}`);
    }
  }
  console.log(`\ncreated=${created} skipped=${skipped} failed=${failed}`);
  process.exit(failed ? 1 : 0);
}

main();
