'use strict'
const { SecretsManager } = require('@aws-sdk/client-secrets-manager');
const secretsmanager = new SecretsManager({
    region: process.env.AWS_DEFAULT_REGION
});

const API_ENDPOINT = process.env.API_ENDPOINT.replace(/\/$/, '');
const SECRET_ARN = process.env.SECRET_ARN;
const GRANT_ROLE = process.env.GRANT_ROLE;
const CREATE_PROJECT = process.env.CREATE_PROJECT === 'true';
const CREATE_SUBSCRIPTION = JSON.parse(process.env.CREATE_SUBSCRIPTION || '[]');
const ADD_RESTRICTED_URL = true;

async function callApi(method, path, parameters, data, apiContext) {
    const { credentials } = apiContext;
    const qsString = new URLSearchParams({
        'api-user': credentials.username,
        'api-key': credentials.key
    });
    const url = `${API_ENDPOINT}/${path}?${qsString}${parameters ? `&${parameters}` : ''}`;
    console.log(`${method} ${path}${parameters ? `?${parameters}` : ''}`, data);
    const response = await fetch(url, {
        method,
        headers: { 'content-type': 'application/json' },
        body: method === 'GET' ? undefined : (typeof data === 'string' ? data : (data === null || typeof data === 'undefined' ? '' : JSON.stringify(data)))
    });
    if (response.status === 404) {
        return null;
    }
    const body = await response.text();
    if (!response.ok) {
        throw new Error(`Request failed. status: ${response.status}, body: ${body}`);
    }
    return response.headers.get('content-type')?.includes('application/json') ? JSON.parse(body) : body;
}
exports.handler = async (event, context) => {
    console.log(JSON.stringify(event));
    console.log(JSON.stringify(context));
    const username = event.userName;

    // Get API key from secret
    const secretHolder = await secretsmanager.getSecretValue({
        SecretId: SECRET_ARN
    });
    const apiContext = {
        credentials: JSON.parse(secretHolder.SecretString)
    };

    try {
        await completeData(apiContext, username, event.request.userAttributes.email, GRANT_ROLE, CREATE_PROJECT, CREATE_SUBSCRIPTION);
    } catch (e) {
        console.log('Application welcome creation failed', e);
    }

    return event;
};

async function getRoleByName(apiContext, role) {
    const userRoles = await callApi('GET', `system/security/role`, null, null, apiContext);
    return userRoles.data.filter(r => r.name === role).map(r => r.id);
}
async function completeData(apiContext, username, email, grantRole, createProject, createSubscriptions) {
    const userRoles = await callApi('GET', `system/user/roles`, `filters=${encodeURIComponent(JSON.stringify({ rules: [{ op: 'eq', field: 'login', data: username }] }))}`, null, apiContext);
    console.log("userRoles", userRoles);
    if (userRoles?.data?.length) {
        // User exists
        console.log("User already exists, add missing roles as needed");
        if (grantRole && userRoles.data[0].roles.filter(r => r === grantRole).length === 0) {
            // Add this role
            console.log("Role need to be added");
            const userUpdate = await callApi('PUT', `system/user`, null, { login: username, roles: [...userRoles.data[0].roles.map(r => r.id), ...await getRoleByName(apiContext, grantRole)] }, apiContext);
            console.log("User update", userUpdate);
        } else {
            console.log("No additional role is needed");
        }
    } else {
        // Create user
        const userCreate = await callApi('POST', `system/user`, null, { login: username, roles: grantRole ? [...await getRoleByName(apiContext, grantRole)] : [] }, apiContext);
        console.log("User created", userCreate);
    }

    if (createProject) {
        // Create the project owned by this user
        const projectKey = `welcome-${username}`;
        const project = await callApi('GET', `project/${projectKey}`, null, null, apiContext);
        let projectId = 0;
        console.log("Existing project", project);
        if (project === null) {
            // Project does not exist yet, create it
            const projectName = `Welcome ${email}`;
            projectId = await callApi('POST', `project`, null, { pkey: projectKey, name: projectName, teamLeader: username, description: `Personal project of ${username}` }, apiContext);
            console.log("Project created", projectId);
        } else {
            projectId = project.id;
        }

        // Create subscription as needed
        const subscriptions = createSubscriptions.filter(s1 => project === null || project.subscriptions.filter(s0 => s0.node.id === s1.node).length === 0);
        for (const s of subscriptions) {
            console.log("Subscription create ...", s);
            const subscriptionId = await callApi('POST', `subscription`, null, { mode: 'create', ...s, project: projectId, node: s.node, parameters: s.parameters || [] }, apiContext);
            console.log("Subscription created", subscriptionId);

            if (ADD_RESTRICTED_URL && subscriptions.length === 1) {
                // Add restricted URL for SaaS mode
                const restrictedHash = `#/home/project/${projectId}/subscription/${subscriptionId}`;
                const userSetting = await callApi('POST', `system/admin-setting/${encodeURIComponent(username)}/restricted-hash/${encodeURIComponent(restrictedHash)}`, null, null, apiContext);
                console.log("User setting restricted-hash", userSetting);
            }
        }
    }
}
