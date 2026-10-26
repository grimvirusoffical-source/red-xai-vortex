const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');

// Run the real parser without booting the UI, contacting a provider or enqueuing work.
const app = fs.readFileSync(path.join(__dirname, 'app.js'), 'utf8');
const start = app.indexOf('function parseMediaCmd(');
const end = app.indexOf('\nfunction mRender(', start);
assert.ok(start >= 0 && end > start, 'real media parser boundaries');
const parser = vm.runInNewContext(app.slice(start, end) + '\nparseMediaCmd;', {
  fetch() { throw new Error('Parsing a message must not contact a service.'); },
});
const parse = input => {
  const result = parser(input);
  return result === null ? null : JSON.parse(JSON.stringify(result));
};

test('explicit natural requests route to the existing media kinds', () => {
  const cases = [
    ['generate an image of a golden fox', 'image', 'a golden fox'],
    ['Create a picture showing a quiet mountain lake', 'image', 'a quiet mountain lake'],
    ['draw me a photo of the northern lights', 'image', 'the northern lights'],
    ['paint an illustration of a seaside village', 'image', 'a seaside village'],
    ['render artwork about a city in the clouds', 'image', 'a city in the clouds'],
    ['create a video showing clouds over the sea', 'video', 'clouds over the sea'],
    ['make a short clip of a moonrise', 'video', 'a moonrise'],
    ['make music for a quiet night', 'music', 'a quiet night'],
    ['create a song about coming home', 'music', 'coming home'],
    ['generate a sound effect of rain on glass', 'sfx', 'rain on glass'],
    ['make a sound of a door closing', 'sfx', 'a door closing'],
    ['create speech that says Welcome home', 'speech', 'Welcome home'],
    ['generate a voiceover saying The story begins here', 'speech', 'The story begins here'],
    ['generate an image of a music player on a desk', 'image', 'a music player on a desk'],
    ['Create an image of prompt cards on a table', 'image', 'prompt cards on a table'],
  ];
  for (const [input, type, prompt] of cases) assert.deepEqual(parse(input), {type, prompt}, input);
});

test('polite generation preserves exact quoted options, numeric controls and multiline prompts', () => {
  assert.deepEqual(parse('Please could you render an image showing café at dusk --size 768x512 --quality high --style "oil paint" --format jpeg'), {
    type: 'image', size: '768x512', quality: 'high', style: 'oil paint', format: 'jpeg', prompt: 'café at dusk',
  });
  assert.deepEqual(parse('Would you create a video showing moonrise\nabove the sea --frames 81 --duration 4 --quality high'), {
    type: 'video', frames: 81, duration: 4, quality: 'high', prompt: 'moonrise\nabove the sea',
  });
  assert.deepEqual(parse("Can you generate speech saying Welcome home --speed 1.25 --style 'gentle narration' --format wav"), {
    type: 'speech', speed: 1.25, style: 'gentle narration', format: 'wav', prompt: 'Welcome home',
  });
});

test('existing slash aliases and exact specifications remain backward compatible', () => {
  assert.deepEqual(parse(' /IMG a fox --size 512x768 --style "ink wash" --format png '), {
    type: 'image', size: '512x768', style: 'ink wash', format: 'png', prompt: 'a fox',
  });
  assert.deepEqual(parse('/image editor interface'), {type: 'image', prompt: 'editor interface'});
  assert.deepEqual(parse('/tts Good morning --speed 0.9'), {type: 'speech', speed: 0.9, prompt: 'Good morning'});
  assert.deepEqual(parse('/SOUND rain on glass --duration 4.5'), {type: 'sfx', duration: 4.5, prompt: 'rain on glass'});
  assert.deepEqual(parse('/music an ambient track --duration 20'), {type: 'music', duration: 20, prompt: 'an ambient track'});
});

test('negation, help, ordinary discussion and incomplete requests stay in chat', () => {
  const inputs = [
    "Don't generate an image of a fox.",
    'Do not create a video showing clouds.',
    'Please do not make music for this.',
    'Please never draw a picture of that.',
    'I do not want you to generate an image.',
    'Can you help me generate an image?',
    'Could you explain how to create a video?',
    'How do I generate an image?',
    'What does the /image command do?',
    'Tell me how to make music.',
    'Show me how to write a speech.',
    'I want to discuss image generation.',
    'The video is ready to review.',
    'Make the code easier to understand.',
    'Create a project for my research.',
    'Generate an image',
    'Create a video',
    'Make music',
    '/imagery is a word, not a command',
    '',
  ];
  assert.deepEqual(inputs.filter(input => parse(input) !== null), []);
});

test('requests for prompts, editors, players and generation code do not enqueue media', () => {
  const inputs = [
    'Generate an image prompt for a golden fox',
    'Create an image editor in JavaScript',
    'Create an image    editor in JavaScript',
    'Make a music player for my app',
    'Create a video generation script in Python',
  ];
  assert.deepEqual(inputs.filter(input => parse(input) !== null), []);
});
