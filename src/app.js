import express from 'express';

const notes = [{ id: 1, text: 'Hello from AWS' }];

export const createApp = () => {
  const app = express();
  app.use(express.json());

  app.get('/health', (req, res) => {
    res.status(200).json({ status: 'ok', commit: process.env.APP_COMMIT ?? 'dev' });
  });

  app.get('/', (req, res) => {
    res.status(200).json({ message: 'Hello from my Express server on AWS! Deploy pipeline verified.' });
  });

  app.get('/api/notes', (req, res) => {
    res.status(200).json(notes);
  });

  app.post('/api/notes', (req, res) => {
    const { text } = req.body ?? {};
    if (typeof text !== 'string' || text.trim() === '') {
      return res.status(400).json({ error: 'text is required' });
    }
    const note = { id: notes.length + 1, text: text.trim() };
    notes.push(note);
    res.status(201).json(note);
  });

  app.use((req, res) => {
    res.status(404).json({ error: 'not found' });
  });

  app.use((err, req, res, next) => {
    res.status(400).json({ error: 'invalid JSON' });
  });

  return app;
};
