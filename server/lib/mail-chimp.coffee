config = require '../../server_config'
MailChimp = require('mailchimp-api-v3')
api = new MailChimp(config.mail.mailchimpAPIKey or '00000000000000000000000000000000-us1')

MAILCHIMP_LIST_ID = 'e9851239eb'
MAILCHIMP_GROUP_ID = '4529'

# These three need to be parallel
interests = [
  {
    "mailChimpLabel": "Artisans",
    "property": "artisanNews",
    "mailChimpId": "4f9b3f5895"
  },
  {
    "mailChimpLabel": "Archmages",
    "property": "archmageNews",
    "mailChimpId": "4f668727b3"
  },
  {
    "mailChimpLabel": "Scribes",
    "property": "scribeNews",
    "mailChimpId": "a8b435ed50"
  },
  {
    "mailChimpLabel": "Diplomats",
    "property": "diplomatNews",
    "mailChimpId": "878a6cd8c1"
  },
  {
    "mailChimpLabel": "Ambassadors",
    "property": "ambassadorNews",
    "mailChimpId": "eb02f46540"
  },
  {
    "mailChimpLabel": "Teachers",
    "property": "teacherNews",
    "mailChimpId": "f6b8104635"
  }
]

crypto = require 'crypto'

makeSubscriberUrl = (email) ->
  return '' unless email
  # http://developer.mailchimp.com/documentation/mailchimp/guides/manage-subscribers-with-the-mailchimp-api/
  subscriberHash = crypto.createHash('md5').update(email.toLowerCase()).digest('hex')
  return "/lists/#{MAILCHIMP_LIST_ID}/members/#{subscriberHash}"

module.exports = {
  api
  makeSubscriberUrl
  MAILCHIMP_LIST_ID
  MAILCHIMP_GROUP_ID
  interests
}
