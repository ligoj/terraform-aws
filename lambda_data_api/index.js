'use strict'
const { Client } = require('pg');
const DB_HOST = process.env.DB_HOST;
const DB_DATABASE = process.env.DB_DATABASE;

async function run(database, query, secret, params) {
    const client = new Client({
        // A 'null' database targets the maintenance database, required for CREATE DATABASE
        database: database === null ? 'postgres' : (database ?? DB_DATABASE),
        host: DB_HOST,
        user: secret.username,
        password: secret.password,
        ssl: { rejectUnauthorized: false },
    });
    await client.connect();
    try {
        return params ? await client.query(query, params) : await client.query(query);
    } finally {
        await client.end();
    }
}

exports.handler = async (event) => {
    console.log('event', JSON.stringify({ ...event, secret: '***' }));
    const query = Buffer.from(event.query, 'base64').toString('utf-8');
    const secret = JSON.parse(Buffer.from(event.secret, 'base64'));
    const params = event.params && JSON.parse(Buffer.from(event.params, 'base64').toString('utf-8'));
    console.log('query', query);
    let result = await run(event.database, query, secret, params);
    // A multi-statement query returns one result per statement: keep the last one
    result = Array.isArray(result) ? result[result.length - 1] : result;
    console.log('result', result.command, result.rowCount);
    if (result.command === 'SELECT') {
        return { records: result.rows };
    }
    return { command: result.command, affectedRows: result.rowCount ?? 0 };
};
