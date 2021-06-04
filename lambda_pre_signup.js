'use strict'
exports.handler = async(event) => {
    console.log(JSON.stringify(event));
    event.request.userAttributes.email = event.request.userAttributes.email || '';
    if (!event.request.userAttributes.email.match(process.env.ACCEPTED_MAIL)) {
        // Corporate user
        console.error('Invalid signup attempt for ' + event.request.userAttributes.email);
        throw new Error(process.env.REJECT_MAIL_MESSAGE);
    }
    return event;
};
