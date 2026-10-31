import { decodeRecording } from './workout-model.js';
self.onmessage=({data})=>{try{self.postMessage({result:decodeRecording(data)});}catch(error){self.postMessage({error:error.message});}};
