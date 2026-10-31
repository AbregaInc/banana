// One bounded working set. A pending window is shared by newer sentences as well as
// finished reads. The owner clears it on refresh, account changes and permission updates.
export class CalendarWindowCache {
  #entries=new Map();
  constructor(limit=8){this.limit=limit;}
  read(key,load){
    if(this.#entries.has(key))return this.#entries.get(key).work;
    if(this.#entries.size>=this.limit){const oldest=this.#entries.keys().next().value;this.#entries.get(oldest).controller.abort();this.#entries.delete(oldest);}
    const controller=new AbortController();
    const work=Promise.resolve().then(()=>load(controller.signal)).catch(error=>{
      if(this.#entries.get(key)?.work===work)this.#entries.delete(key);
      throw error;
    });
    this.#entries.set(key,{work,controller});return work;
  }
  clear(){for(const entry of this.#entries.values())entry.controller.abort();this.#entries.clear();}
}
